--[[--
MediaAligner -- Generate sentence-level and word-level alignment between text and audio.
Uses ffmpeg silence detection for sentence boundaries and espeak-ng phoneme timing
for word-level granularity. Produces JSON consumed by MediaSync.

@module koplugin.audiobook.mediaaligner
--]]

local logger = require("logger")
local _ = require("audiobook_gettext")

local MediaAligner = {}

function MediaAligner:new(o)
    o = o or {}
    setmetatable(o, self)
    self.__index = self
    o._plugin_dir = o.plugin_dir or "."
    return o
end

-- ---------------------------------------------------------------------------
-- Utility
-- ---------------------------------------------------------------------------

function MediaAligner:_commandExists(cmd)
    local handle = io.popen("command -v " .. cmd .. " 2>/dev/null")
    if not handle then return false end
    local result = handle:read("*l")
    handle:close()
    return result ~= nil and result ~= ""
end

function MediaAligner:_formatTime(seconds)
    seconds = math.floor(seconds or 0)
    local mins = math.floor(seconds / 60)
    local secs = seconds % 60
    return string.format("%d:%02d", mins, secs)
end

-- ---------------------------------------------------------------------------
-- Sentence-level alignment via ffmpeg silencedetect
-- ---------------------------------------------------------------------------

function MediaAligner:_detectSilences(audio_path)
    if not self:_commandExists("ffmpeg") then
        return nil, "ffmpeg not found"
    end

    local cmd = string.format(
        'ffmpeg -i "%s" -af silencedetect=noise=-50dB:d=0.5 -f null - 2>&1',
        audio_path:gsub('"', '\\"')
    )
    local h = io.popen(cmd)
    if not h then return nil, "failed to run ffmpeg" end
    local out = h:read("*a") or ""
    h:close()

    local silences = {}
    for silence_start, silence_end in out:gmatch("silence_start:%s*([%d%.]+)[^\n]*\n[^\n]*silence_end:%s*([%d%.]+)") do
        table.insert(silences, {
            start = tonumber(silence_start),
            ["end"] = tonumber(silence_end),
        })
    end

    -- Also capture final silence_start without end (end of file)
    local last_start = out:match("silence_start:%s*([%d%.]+)[^\n]*\n[^\n]*$")
    if last_start then
        table.insert(silences, {
            start = tonumber(last_start),
            ["end"] = nil, -- end of file
        })
    end

    logger.dbg("MediaAligner: detected", #silences, "silence regions")
    return silences
end

function MediaAligner:_silencesToBoundaries(silences, total_duration)
    -- Convert silence regions to segment boundaries.
    -- Each segment is the audio between two silences.
    local boundaries = {0}
    for _, s in ipairs(silences) do
        if s.start and s.start > 0 then
            table.insert(boundaries, s.start)
        end
        if s["end"] then
            table.insert(boundaries, s["end"])
        end
    end
    if total_duration and boundaries[#boundaries] < total_duration then
        table.insert(boundaries, total_duration)
    end
    -- Sort and deduplicate
    table.sort(boundaries)
    local uniq = {}
    local last = -1
    for _, b in ipairs(boundaries) do
        if b ~= last then
            table.insert(uniq, b)
            last = b
        end
    end
    return uniq
end

function MediaAligner:_alignSentencesToSegments(sentences, boundaries)
    -- Map each sentence to a time segment using greedy length matching.
    -- We assume the number of sentences roughly matches the number of segments.
    local result = {}
    local num_sentences = #sentences
    local num_segments = #boundaries - 1

    if num_segments <= 0 or num_sentences <= 0 then
        return result
    end

    -- Calculate sentence "weights" (character counts)
    local weights = {}
    local total_weight = 0
    for i, sent in ipairs(sentences) do
        local w = #sent.text
        weights[i] = w
        total_weight = total_weight + w
    end

    -- Assign sentences to segments proportionally
    local seg_idx = 1
    local seg_start = boundaries[1]
    local seg_weight_used = 0
    local seg_target_weight = (total_weight / num_segments) * (boundaries[2] - boundaries[1])

    for sent_idx, sent in ipairs(sentences) do
        local sent_weight = weights[sent_idx]

        -- If we've exceeded the segment, move to next
        while seg_idx < num_segments and seg_weight_used + sent_weight > seg_target_weight * 1.5 do
            seg_idx = seg_idx + 1
            seg_start = boundaries[seg_idx]
            seg_weight_used = 0
            local seg_duration = boundaries[seg_idx + 1] - boundaries[seg_idx]
            seg_target_weight = (total_weight / num_segments) * seg_duration
        end

        local seg_end = boundaries[seg_idx + 1] or (seg_start + 5)
        table.insert(result, {
            text = sent.text,
            start_time = seg_start,
            end_time = seg_end,
            start_pos = sent.start_pos or 0,
            end_pos = sent.end_pos or #sent.text,
        })

        seg_weight_used = seg_weight_used + sent_weight
    end

    return result
end

-- ---------------------------------------------------------------------------
-- Word-level alignment via espeak-ng phoneme timing
-- ---------------------------------------------------------------------------

function MediaAligner:_getEspeakPhonemes(text)
    if not self:_commandExists("espeak-ng") then
        return nil, "espeak-ng not found"
    end

    -- Run espeak-ng with -x (phoneme output) and -X (trace)
    local cmd = string.format(
        'espeak-ng -x -X -q "%s" 2>&1',
        text:gsub('"', '\\"')
    )
    local h = io.popen(cmd)
    if not h then return nil, "failed to run espeak-ng" end
    local out = h:read("*a") or ""
    h:close()

    -- Parse phoneme timing from espeak output
    -- Format: "p  10" where p is phoneme and 10 is duration in ms
    local phonemes = {}
    for phoneme, dur_ms in out:gmatch("(%S+)%s+(%d+)") do
        table.insert(phonemes, {
            phoneme = phoneme,
            duration_ms = tonumber(dur_ms),
        })
    end

    return phonemes
end

function MediaAligner:_splitTextIntoWords(text)
    local words = {}
    for word in text:gmatch("%S+") do
        -- Clean punctuation for matching
        local clean = word:gsub("^[%p%s]+", ""):gsub("[%p%s]+$", "")
        if clean ~= "" then
            table.insert(words, clean)
        end
    end
    return words
end

function MediaAligner:_alignWordsInSentence(sentence_entry, text_words)
    -- Use espeak to get phoneme durations, then map to words.
    local phonemes, err = self:_getEspeakPhonemes(sentence_entry.text)
    if not phonemes or #phonemes == 0 then
        return nil, err
    end

    -- Calculate total espeak-estimated duration
    local total_espeak_ms = 0
    for _, p in ipairs(phonemes) do
        total_espeak_ms = total_espeak_ms + p.duration_ms
    end

    if total_espeak_ms <= 0 then
        return nil, "zero espeak duration"
    end

    -- Scale factor to match actual audio duration
    local actual_duration_ms = (sentence_entry.end_time - sentence_entry.start_time) * 1000
    local scale = actual_duration_ms / total_espeak_ms

    -- Map phonemes to words (simplified: proportional by character count)
    local words = {}
    local current_time_ms = 0

    for i, word_text in ipairs(text_words) do
        -- Estimate this word's espeak duration proportionally
        local word_chars = #word_text
        local total_chars = #sentence_entry.text
        local word_espeak_ms = (word_chars / total_chars) * total_espeak_ms

        local word_start_ms = current_time_ms
        local word_end_ms = current_time_ms + word_espeak_ms * scale

        table.insert(words, {
            text = word_text,
            start_time = sentence_entry.start_time + (word_start_ms / 1000),
            end_time = sentence_entry.start_time + (word_end_ms / 1000),
            start_pos = sentence_entry.start_pos,
            end_pos = sentence_entry.end_pos,
        })

        current_time_ms = word_end_ms
    end

    return words
end

-- ---------------------------------------------------------------------------
-- Main alignment entry points
-- ---------------------------------------------------------------------------

function MediaAligner:alignEpubAudio(epub_path, audio_path, text_parser, output_path)
    -- TODO: Extract all text from EPUB across all chapters.
    -- For now, this requires the caller to provide parsed text.
    return nil, "EPUB text extraction not yet implemented. Use alignTextAudio instead."
end

function MediaAligner:alignTextAudio(text, audio_path, output_path)
    -- text: plain string with the book text
    -- audio_path: path to audio file (mp3, m4b, etc.)
    -- output_path: where to write the JSON alignment file

    if not text or text == "" then
        return nil, "empty text"
    end
    if not audio_path or audio_path == "" then
        return nil, "empty audio path"
    end

    -- Step 1: Get audio duration
    local duration = nil
    if self:_commandExists("ffprobe") then
        local cmd = string.format(
            'ffprobe -v error -show_entries format=duration -of csv=p=0 "%s" 2>/dev/null',
            audio_path:gsub('"', '\\"')
        )
        local h = io.popen(cmd)
        if h then
            local out = h:read("*a") or ""
            h:close()
            duration = tonumber(out:match("^%s*([%d%.]+)"))
        end
    end

    -- Step 2: Parse text into sentences
    -- We need TextParser; load it dynamically
    local _utils_dir = debug.getinfo(1, "S").source:match("^@(.*/)[^/]*$") or "./"
    local TextParser = dofile(_utils_dir .. "textparser.lua")
    local parser = TextParser:new()
    local parsed = parser:parse(text)

    if not parsed or not parsed.sentences or #parsed.sentences == 0 then
        return nil, "no sentences found in text"
    end

    logger.warn("MediaAligner: aligning", #parsed.sentences, "sentences")

    -- Step 3: Sentence-level alignment
    local silences = self:_detectSilences(audio_path)
    local boundaries
    if silences then
        boundaries = self:_silencesToBoundaries(silences, duration)
    else
        -- Fallback: equal time distribution
        boundaries = {}
        local num_sentences = #parsed.sentences
        local total_dur = duration or (num_sentences * 5)
        for i = 0, num_sentences do
            table.insert(boundaries, (i / num_sentences) * total_dur)
        end
    end

    local sentence_alignments = self:_alignSentencesToSegments(parsed.sentences, boundaries)

    -- Step 4: Word-level alignment (best effort)
    local has_word_level = false
    for i, sent_align in ipairs(sentence_alignments) do
        local text_words = self:_splitTextIntoWords(sent_align.text)
        if #text_words > 0 then
            local words = self:_alignWordsInSentence(sent_align, text_words)
            if words and #words > 0 then
                sent_align.words = words
                has_word_level = true
            end
        end
    end

    -- Step 5: Build output JSON
    local output = {
        format = "audiobook-alignment-v1",
        source_audio = audio_path,
        granularity = has_word_level and "word" or "sentence",
        sentences = sentence_alignments,
    }

    -- Write JSON file
    local json_str = self:_encodeJson(output)
    local f = io.open(output_path, "w")
    if not f then
        return nil, "cannot write to " .. output_path
    end
    f:write(json_str)
    f:close()

    logger.warn("MediaAligner: wrote alignment to", output_path,
        "granularity=", output.granularity)
    return output, nil
end

-- ---------------------------------------------------------------------------
-- JSON encoder (lightweight, sufficient for our constrained format)
-- ---------------------------------------------------------------------------

function MediaAligner:_encodeJson(value, indent)
    indent = indent or 0
    local indent_str = string.rep("  ", indent)

    if type(value) == "table" then
        -- Check if array-like (sequential integer keys)
        local is_array = true
        local max_key = 0
        for k, _ in pairs(value) do
            if type(k) ~= "number" or k < 1 or math.floor(k) ~= k then
                is_array = false
                break
            end
            if k > max_key then max_key = k end
        end
        if is_array and max_key ~= #value then
            is_array = false
        end

        if is_array then
            if #value == 0 then return "[]" end
            local parts = {"[\n"}
            for i, v in ipairs(value) do
                table.insert(parts, indent_str .. "  " .. self:_encodeJson(v, indent + 1))
                if i < #value then
                    table.insert(parts, ",")
                end
                table.insert(parts, "\n")
            end
            table.insert(parts, indent_str .. "]")
            return table.concat(parts)
        else
            if not next(value) then return "{}" end
            local parts = {"{\n"}
            local keys = {}
            for k, _ in pairs(value) do
                table.insert(keys, k)
            end
            table.sort(keys)
            for i, k in ipairs(keys) do
                table.insert(parts, indent_str .. "  " .. self:_encodeString(tostring(k)) .. ": " .. self:_encodeJson(value[k], indent + 1))
                if i < #keys then
                    table.insert(parts, ",")
                end
                table.insert(parts, "\n")
            end
            table.insert(parts, indent_str .. "}")
            return table.concat(parts)
        end
    elseif type(value) == "string" then
        return self:_encodeString(value)
    elseif type(value) == "number" then
        -- Format with up to 3 decimal places, trimming trailing zeros
        local s = string.format("%.3f", value)
        s = s:gsub("0+$", ""):gsub("%.$", "")
        return s
    elseif type(value) == "boolean" then
        return value and "true" or "false"
    elseif type(value) == "nil" then
        return "null"
    end
    return self:_encodeString(tostring(value))
end

function MediaAligner:_encodeString(str)
    -- Escape special JSON characters
    str = str:gsub("\\", "\\\\")
    str = str:gsub('"', '\\"')
    str = str:gsub("\b", "\\b")
    str = str:gsub("\f", "\\f")
    str = str:gsub("\n", "\\n")
    str = str:gsub("\r", "\\r")
    str = str:gsub("\t", "\\t")
    return '"' .. str .. '"'
end

return MediaAligner
