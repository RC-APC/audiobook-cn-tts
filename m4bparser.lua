--[[--
Metadata Parser -- Extract chapters and cover art from audiobook files.
Primary method: ffprobe (works for M4B, MP3, OGG, FLAC, Opus).
Fallbacks: minimal Lua parsers for MP3 (ID3v2 CHAP) and OGG (VorbisComment).

@module koplugin.audiobook.m4bparser
--]]

local logger = require("logger")

local MetadataParser = {}
MetadataParser.__index = MetadataParser

function MetadataParser:new(opts)
    local o = opts or {}
    setmetatable(o, self)
    return o
end

-- ---------------------------------------------------------------------------
-- Utilities
-- ---------------------------------------------------------------------------

function MetadataParser:_findTool(cmd)
    -- Check PATH first, then plugin bin/ directory
    local handle = io.popen("command -v " .. cmd .. " 2>/dev/null")
    if handle then
        local result = handle:read("*l")
        handle:close()
        if result and result ~= "" then
            logger.warn("MetadataParser: found", cmd, "in PATH at", result)
            return result
        end
    end
    -- Check plugin bin/ directory
    if self.plugin_dir then
        local plugin_cmd = self.plugin_dir .. "/bin/" .. cmd
        logger.dbg("MetadataParser: checking plugin path", plugin_cmd)
        local f = io.open(plugin_cmd, "r")
        if f then
            f:close()
            logger.warn("MetadataParser: found", cmd, "in plugin bin at", plugin_cmd)
            return plugin_cmd
        end
    end
    logger.warn("MetadataParser:", cmd, "not found")
    return nil
end

function MetadataParser:_commandExists(cmd)
    return self:_findTool(cmd) ~= nil
end

function MetadataParser:_md5(text)
    -- Simple hash for cache filenames. Not cryptographic, just needs to be
    -- consistent and low-collision for file paths.
    local h = io.popen('echo -n ' .. text:gsub("'", "'\\''") .. " | md5sum 2>/dev/null | awk '{print $1}'")
    if h then
        local hash = h:read("*l")
        h:close()
        if hash and #hash == 32 then return hash end
    end
    -- Fallback: simple string hash
    local hash_val = 0
    for i = 1, #text do
        hash_val = (hash_val * 31 + text:byte(i)) % 4294967296
    end
    return string.format("%08x", hash_val)
end

function MetadataParser:_parseJson(json_str)
    -- Lightweight JSON parser for ffprobe output.
    local chapters = {}
    local chapters_block = json_str:match('"chapters"%s*:%s*(%[.-%])')
    if not chapters_block then return chapters end

    for chapter_json in chapters_block:gmatch('(%{.-%})') do
        local id = tonumber(chapter_json:match('"id"%s*:%s*(%d+)'))
        local start_val = tonumber(chapter_json:match('"start"%s*:%s*(%d+)'))
        local end_val = tonumber(chapter_json:match('"end"%s*:%s*(%d+)'))
        local time_base = chapter_json:match('"time_base"%s*:%s*"([%d/]+)"') or "1/1000"
        local title = chapter_json:match('"title"%s*:%s*"(.-)"') or ("Chapter " .. (id and id + 1 or "?"))

        if start_val and end_val then
            local tb_num, tb_den = time_base:match("(%d+)%s*/%s*(%d+)")
            local scale = 1
            if tb_num and tb_den then
                scale = tonumber(tb_num) / tonumber(tb_den)
            end
            table.insert(chapters, {
                id = id,
                title = title,
                start_time = start_val * scale,
                end_time = end_val * scale,
            })
        end
    end

    return chapters
end

-- ---------------------------------------------------------------------------
-- ffprobe-based parsing (primary, works for all formats)
-- ---------------------------------------------------------------------------

function MetadataParser:parseWithFfprobe(path)
    logger.warn("MetadataParser: parseWithFfprobe called for", path)
    local ffprobe_path = self:_findTool("ffprobe")
    if not ffprobe_path then
        logger.warn("MetadataParser: ffprobe not found, skipping")
        return nil, "ffprobe not found"
    end

    local cmd = string.format(
        '"%s" -v quiet -print_format json -show_chapters -show_format "%s" 2>/dev/null',
        ffprobe_path:gsub('"', '\\"'),
        path:gsub('"', '\\"')
    )
    logger.warn("MetadataParser: running ffprobe cmd")
    local h = io.popen(cmd)
    if not h then return nil, "failed to run ffprobe" end
    local json_str = h:read("*a") or ""
    h:close()

    if json_str == "" then
        return nil, "ffprobe produced no output"
    end

    local chapters = self:_parseJson(json_str)

    local duration = nil
    local dur_match = json_str:match('"duration"%s*:%s*"([%d%.]+)"')
    if dur_match then
        duration = tonumber(dur_match)
    end

    logger.dbg("MetadataParser: ffprobe found", #chapters, "chapters, duration=", duration)
    return chapters, duration
end

-- ---------------------------------------------------------------------------
-- Fallback: minimal MP4 atom parser (M4B/M4A)
-- ---------------------------------------------------------------------------

function MetadataParser:_readUint32BE(data, offset)
    local b1, b2, b3, b4 = data:byte(offset, offset + 3)
    if not b4 then return nil end
    return b1 * 16777216 + b2 * 65536 + b3 * 256 + b4
end

function MetadataParser:_parseAtoms(data)
    local atoms = {}
    local pos = 1
    while pos <= #data - 8 do
        local size = self:_readUint32BE(data, pos)
        if not size or size < 8 then break end
        local atom_type = data:sub(pos + 4, pos + 7)
        if #atom_type ~= 4 then break end
        table.insert(atoms, {
            type = atom_type,
            start = pos,
            size = size,
            data = data:sub(pos + 8, pos + size - 1),
        })
        pos = pos + size
    end
    return atoms
end

function MetadataParser:_findAtom(atoms, atom_type)
    for _, atom in ipairs(atoms) do
        if atom.type == atom_type then
            return atom
        end
    end
    return nil
end

function MetadataParser:_parseMp4Fallback(path)
    local f = io.open(path, "rb")
    if not f then return nil, "cannot open file" end
    local data = f:read(65536)
    f:close()
    if not data or #data < 64 then
        return nil, "file too small"
    end

    local atoms = self:_parseAtoms(data)
    local moov = self:_findAtom(atoms, "moov")
    if not moov then
        return nil, "no moov atom found"
    end

    local moov_children = self:_parseAtoms(moov.data)
    local mvhd = self:_findAtom(moov_children, "mvhd")
    local duration = nil
    local timescale = nil

    if mvhd and mvhd.size >= 24 then
        local version = mvhd.data:byte(1)
        if version == 0 then
            timescale = self:_readUint32BE(mvhd.data, 13)
            duration = self:_readUint32BE(mvhd.data, 17)
        else
            timescale = self:_readUint32BE(mvhd.data, 21)
            duration = self:_readUint32BE(mvhd.data, 29)
        end
    end

    if timescale and timescale > 0 and duration then
        duration = duration / timescale
    else
        duration = nil
    end

    logger.dbg("MetadataParser: MP4 fallback duration=", duration)
    return {}, duration
end

-- ---------------------------------------------------------------------------
-- Fallback: minimal ID3v2 parser (MP3)
-- ---------------------------------------------------------------------------

function MetadataParser:_readSynchsafeInt(data, offset)
    local b1, b2, b3, b4 = data:byte(offset, offset + 3)
    if not b4 then return nil end
    return (b1 % 128) * 2097152 + (b2 % 128) * 16384 + (b3 % 128) * 128 + (b4 % 128)
end

function MetadataParser:_parseId3v2Frames(data, offset, size_limit)
    -- Returns a list of frames: {id=string, data=string}
    local frames = {}
    local pos = offset
    local end_pos = offset + size_limit
    while pos <= end_pos - 10 do
        local frame_id = data:sub(pos, pos + 3)
        if frame_id:match("^%x%x%x%x$") == nil or frame_id == "\x00\x00\x00\x00" then
            break -- padding or end of tag
        end
        local frame_size
        local major_ver = data:byte(1)
        if major_ver == 4 or major_ver == 3 then
            frame_size = self:_readUint32BE(data, pos + 4) or 0
        else
            frame_size = self:_readSynchsafeInt(data, pos + 4) or 0
        end
        if frame_size < 1 or frame_size > size_limit then break end
        table.insert(frames, {
            id = frame_id,
            data = data:sub(pos + 10, pos + 10 + frame_size - 1),
        })
        pos = pos + 10 + frame_size
    end
    return frames
end

function MetadataParser:_readId3String(frame_data)
    -- ID3 text encoding: 0=ISO-8859-1, 1=UTF-16 BOM, 2=UTF-16BE, 3=UTF-8
    if #frame_data < 2 then return "" end
    local encoding = frame_data:byte(1)
    local text = frame_data:sub(2)
    if encoding == 0 or encoding == 3 then
        return text:gsub("%z", "")
    elseif encoding == 1 or encoding == 2 then
        -- UTF-16: strip BOM and nulls, best effort
        if text:sub(1, 2) == "\xff\xfe" or text:sub(1, 2) == "\xfe\xff" then
            text = text:sub(3)
        end
        return text:gsub("%z%z", ""):gsub("%z", "")
    end
    return text:gsub("%z", "")
end

function MetadataParser:_parseMp3Fallback(path)
    local f = io.open(path, "rb")
    if not f then return nil, "cannot open file" end
    local header = f:read(10)
    if not header or header:sub(1, 3) ~= "ID3" then
        f:close()
        return nil, "no ID3 tag"
    end

    local major_ver = header:byte(4)
    local tag_size = self:_readSynchsafeInt(header, 7) or 0
    if tag_size < 1 or tag_size > 1048576 then
        f:close()
        return nil, "invalid ID3 tag size"
    end

    local data = f:read(tag_size)
    f:close()
    if not data or #data < 10 then
        return nil, "truncated ID3 tag"
    end

    -- Prepend version byte so _parseId3v2Frames can read it
    data = string.char(major_ver) .. data

    local frames = self:_parseId3v2Frames(data, 2, #data - 1)
    local chapters = {}
    local duration_ms = nil

    for _, frame in ipairs(frames) do
        if frame.id == "CHAP" then
            -- CHAP frame: element_id (null terminated) + start + end + start_offset + end_offset + sub-frames
            local chap_data = frame.data
            local null_pos = chap_data:find("\x00", 1, true)
            if null_pos then
                local sub_frame_start = null_pos + 17 -- after element_id + 4x4 bytes
                if #chap_data >= sub_frame_start then
                    local start_ms = self:_readUint32BE(chap_data, null_pos + 1) or 0
                    local end_ms = self:_readUint32BE(chap_data, null_pos + 5) or 0
                    -- Parse sub-frames for title
                    local title = nil
                    local sub_data = chap_data:sub(sub_frame_start)
                    if #sub_data >= 10 then
                        local sub_frames = self:_parseId3v2Frames(string.char(major_ver) .. sub_data, 2, #sub_data - 1)
                        for _, sf in ipairs(sub_frames) do
                            if sf.id == "TIT2" then
                                title = self:_readId3String(sf.data)
                                break
                            end
                        end
                    end
                    table.insert(chapters, {
                        id = #chapters,
                        title = title or ("Chapter " .. (#chapters + 1)),
                        start_time = start_ms / 1000,
                        end_time = end_ms / 1000,
                    })
                end
            end
        elseif frame.id == "TLEN" then
            local len_str = self:_readId3String(frame.data)
            duration_ms = tonumber(len_str)
        end
    end

    table.sort(chapters, function(a, b) return a.start_time < b.start_time end)

    local duration = nil
    if duration_ms then
        duration = duration_ms / 1000
    end

    logger.dbg("MetadataParser: MP3 fallback found", #chapters, "chapters, duration=", duration)
    return chapters, duration
end

-- ---------------------------------------------------------------------------
-- Fallback: minimal OGG VorbisComment parser
-- ---------------------------------------------------------------------------

function MetadataParser:_parseOggFallback(path)
    local f = io.open(path, "rb")
    if not f then return nil, "cannot open file" end
    local data = f:read(131072) -- 128KB
    f:close()
    if not data or #data < 64 then
        return nil, "file too small"
    end

    -- OGG pages start with "OggS"
    if data:sub(1, 4) ~= "OggS" then
        return nil, "not an OGG file"
    end

    -- VorbisComment chapter format:
    -- CHAPTER001=00:00:00.000
    -- CHAPTER001NAME=Chapter 1
    local chapters = {}
    local chapter_times = {}
    local chapter_names = {}

    -- Search for CHAPTER patterns in the binary header data
    for idx, time_str in data:gmatch("CHAPTER(%d+)=([%d:]+%.?%d*)") do
        local h, m, s = time_str:match("(%d+):(%d+):([%d%.]+)")
        if h and m and s then
            chapter_times[idx] = tonumber(h) * 3600 + tonumber(m) * 60 + tonumber(s)
        else
            m, s = time_str:match("(%d+):([%d%.]+)")
            if m and s then
                chapter_times[idx] = tonumber(m) * 60 + tonumber(s)
            end
        end
    end

    for idx, name in data:gmatch("CHAPTER(%d+)NAME=([^\r\n]+)") do
        chapter_names[idx] = name
    end

    -- Build sorted chapter list
    local sorted_indices = {}
    for idx, _ in pairs(chapter_times) do
        table.insert(sorted_indices, idx)
    end
    table.sort(sorted_indices, function(a, b) return tonumber(a) < tonumber(b) end)

    for i, idx in ipairs(sorted_indices) do
        local next_time = nil
        if sorted_indices[i + 1] then
            next_time = chapter_times[sorted_indices[i + 1]]
        end
        table.insert(chapters, {
            id = i - 1,
            title = chapter_names[idx] or ("Chapter " .. i),
            start_time = chapter_times[idx],
            end_time = next_time or (chapter_times[idx] + 300),
        })
    end

    logger.dbg("MetadataParser: OGG fallback found", #chapters, "chapters")
    return chapters, nil
end

-- ---------------------------------------------------------------------------
-- Cover art extraction
-- ---------------------------------------------------------------------------

function MetadataParser:extractCoverArt(audio_path, plugin_dir)
    local ffmpeg_path = self:_findTool("ffmpeg")
    if not ffmpeg_path then
        return nil
    end

    local cache_dir = plugin_dir .. "/cache/covers"
    local hash = self:_md5(audio_path)
    local cache_path = cache_dir .. "/" .. hash .. ".jpg"

    -- Check if already cached
    local test = io.open(cache_path, "r")
    if test then
        test:close()
        return cache_path
    end

    -- Ensure cache directory exists
    os.execute("mkdir -p '" .. cache_dir:gsub("'", "'\\''") .. "'")

    local cmd = string.format(
        '"%s" -y -i "%s" -an -vcodec copy -f image2 -vframes 1 "%s" 2>/dev/null',
        ffmpeg_path:gsub('"', '\\"'),
        audio_path:gsub('"', '\\"'),
        cache_path:gsub('"', '\\"')
    )
    logger.dbg("MetadataParser: extracting cover art:", cmd)
    local rc = os.execute(cmd)

    if rc == 0 or rc == true then
        local verify = io.open(cache_path, "r")
        if verify then
            verify:close()
            logger.dbg("MetadataParser: cover art cached at", cache_path)
            return cache_path
        end
    end

    return nil
end

function MetadataParser:clearOldCoverArt(plugin_dir, max_age_days)
    max_age_days = max_age_days or 30
    local cache_dir = plugin_dir .. "/cache/covers"
    -- Use find to delete old files; ignore errors
    local cmd = string.format(
        "find '%s' -type f -mtime +%d -delete 2>/dev/null",
        cache_dir:gsub("'", "'\\''"),
        max_age_days
    )
    os.execute(cmd)
end

-- ---------------------------------------------------------------------------
-- Sidecar chapter files (works on any device, no external tools needed)
-- ---------------------------------------------------------------------------

function MetadataParser:_timeToSeconds(time_str)
    -- Parse HH:MM:SS, MM:SS, or SS
    local h, m, s = time_str:match("(%d+):(%d+):([%d%.]+)")
    if h then
        return tonumber(h) * 3600 + tonumber(m) * 60 + tonumber(s)
    end
    m, s = time_str:match("(%d+):([%d%.]+)")
    if m then
        return tonumber(m) * 60 + tonumber(s)
    end
    return tonumber(time_str)
end

function MetadataParser:_parseSidecarChapters(path)
    -- Look for <audio>.chapters.txt next to the audio file.
    -- Format: one chapter per line, either:
    --   HH:MM:SS Chapter Title
    --   MM:SS Chapter Title
    --   start-end Chapter Title  (e.g. 0:00-10:00 Chapter 1)
    local sidecar_path = path .. ".chapters.txt"
    local f = io.open(sidecar_path, "r")
    if not f then return nil end

    local chapters = {}
    for line in f:lines() do
        line = line:match("^%s*(.-)%s*$") -- trim
        if line ~= "" and not line:match("^#") then
            local start_str, end_str, title = line:match("^([%d:%.]+)%-([%d:%.]+)%s+(.+)$")
            if start_str and end_str then
                local start_sec = self:_timeToSeconds(start_str)
                local end_sec = self:_timeToSeconds(end_str)
                if start_sec and end_sec then
                    table.insert(chapters, {
                        id = #chapters,
                        title = title,
                        start_time = start_sec,
                        end_time = end_sec,
                    })
                end
            else
                local time_str, title = line:match("^([%d:%.]+)%s+(.+)$")
                if time_str and title then
                    local start_sec = self:_timeToSeconds(time_str)
                    if start_sec then
                        table.insert(chapters, {
                            id = #chapters,
                            title = title,
                            start_time = start_sec,
                            end_time = nil, -- will be filled in later
                        })
                    end
                end
            end
        end
    end
    f:close()

    -- Fill in missing end times from next chapter's start
    for i = 1, #chapters do
        if not chapters[i].end_time then
            if chapters[i + 1] then
                chapters[i].end_time = chapters[i + 1].start_time
            else
                chapters[i].end_time = chapters[i].start_time + 300
            end
        end
    end

    if #chapters > 0 then
        logger.dbg("MetadataParser: sidecar found", #chapters, "chapters")
        return chapters, nil
    end
    return nil
end

function MetadataParser:_parseCueSheet(path)
    -- Look for <audio>.cue next to the audio file.
    local cue_path = path:match("^(.*)%.[^%.]+$") .. ".cue"
    local f = io.open(cue_path, "r")
    if not f then return nil end

    local chapters = {}
    local current_title = nil
    local current_index = nil

    for line in f:lines() do
        line = line:match("^%s*(.-)%s*$")
        if line:match("^TRACK") then
            current_title = nil
            current_index = nil
        elseif line:match("^TITLE") then
            current_title = line:match('TITLE%s+"(.-)"') or line:match("TITLE%s+(.+)$")
        elseif line:match("^INDEX 01") then
            local mm, ss, ff = line:match("INDEX%s+01%s+(%d+):(%d+):(%d+)")
            if mm and ss then
                current_index = tonumber(mm) * 60 + tonumber(ss) + tonumber(ff or 0) / 75
            end
        end

        if current_title and current_index then
            table.insert(chapters, {
                id = #chapters,
                title = current_title,
                start_time = current_index,
                end_time = nil,
            })
            current_title = nil
            current_index = nil
        end
    end
    f:close()

    -- Fill in end times
    for i = 1, #chapters do
        if not chapters[i].end_time then
            if chapters[i + 1] then
                chapters[i].end_time = chapters[i + 1].start_time
            else
                chapters[i].end_time = chapters[i].start_time + 300
            end
        end
    end

    if #chapters > 0 then
        logger.dbg("MetadataParser: CUE sheet found", #chapters, "chapters")
        return chapters, nil
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

function MetadataParser:parse(path)
    logger.warn("MetadataParser: parse() called for", path, "plugin_dir=", self.plugin_dir)
    local ext = (path:match("%.([^.]+)$") or ""):lower()

    -- ffprobe handles all formats; try it first
    local chapters, duration = self:parseWithFfprobe(path)
    logger.warn("MetadataParser: ffprobe returned", chapters and #chapters or "nil", "chapters")
    if chapters and #chapters > 0 then
        return chapters, duration
    end

    -- Sidecar files work for any format, no external tools needed
    chapters, duration = self:_parseSidecarChapters(path)
    logger.warn("MetadataParser: sidecar returned", chapters and #chapters or "nil", "chapters")
    if chapters and #chapters > 0 then
        return chapters, duration
    end

    chapters, duration = self:_parseCueSheet(path)
    if chapters and #chapters > 0 then
        return chapters, duration
    end

    -- Format-specific binary fallbacks
    if ext == "mp3" then
        chapters, duration = self:_parseMp3Fallback(path)
    elseif ext == "ogg" or ext == "opus" or ext == "oga" then
        chapters, duration = self:_parseOggFallback(path)
    elseif ext == "m4b" or ext == "m4a" or ext == "mp4" then
        chapters, duration = self:_parseMp4Fallback(path)
    end

    if chapters and #chapters > 0 then
        return chapters, duration
    end

    return {}, duration
end

return MetadataParser
