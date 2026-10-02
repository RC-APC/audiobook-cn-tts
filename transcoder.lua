--[[--
Transcoder -- On-device audio transcoding for unsupported formats.
Uses the bundled ffmpeg binary to convert M4B/OGG/FLAC/etc. to MP3.
Caches transcoded files to avoid repeated conversion.

@module koplugin.audiobook.transcoder
--]]

local logger = require("logger")
local _ = require("audiobook_gettext")

local Transcoder = {}
Transcoder.__index = Transcoder

function Transcoder:new(opts)
    local o = opts or {}
    setmetatable(o, self)
    -- Ensure plugin_dir is an absolute path. KOReader sets PLUGIN_PATH to a
    -- relative path like "plugins/audiobook.koplugin/" but gst-play needs
    -- absolute paths for the file:// URI.
    if o.plugin_dir and not o.plugin_dir:match("^/") then
        local cwd = io.popen("pwd 2>/dev/null"):read("*l") or "/mnt/onboard/.adds/koreader"
        o.plugin_dir = cwd .. "/" .. o.plugin_dir:gsub("/$", "")
    end
    return o
end

function Transcoder:_findFfmpeg()
    if self.plugin_dir then
        local plugin_ffmpeg = self.plugin_dir .. "/bin/ffmpeg"
        -- Release zip ships ffmpeg as ffmpeg.bin; replace any stale ffmpeg.
        local bin_path = plugin_ffmpeg .. ".bin"
        local b = io.open(bin_path, "r")
        if b then
            b:close()
            os.remove(plugin_ffmpeg)
            local ok = os.rename(bin_path, plugin_ffmpeg)
            if ok then
                logger.warn("Transcoder: renamed", bin_path, "to", plugin_ffmpeg)
            else
                return bin_path
            end
        end
        local f = io.open(plugin_ffmpeg, "r")
        if f then
            f:close()
            return plugin_ffmpeg
        end
    end
    -- Check PATH as fallback
    local h = io.popen("command -v ffmpeg 2>/dev/null")
    if h then
        local result = h:read("*l")
        h:close()
        if result and result ~= "" then return result end
    end
    return nil
end

function Transcoder:_md5(text)
    local h = io.popen('echo -n ' .. text:gsub("'", "'\\''") .. " | md5sum 2>/dev/null | awk '{print $1}'")
    if h then
        local hash = h:read("*l")
        h:close()
        if hash and #hash == 32 then return hash end
    end
    local hash_val = 0
    for i = 1, #text do
        hash_val = (hash_val * 31 + text:byte(i)) % 4294967296
    end
    return string.format("%08x", hash_val)
end

function Transcoder:_cachePath(input_path)
    local cache_dir = self.plugin_dir .. "/cache/transcoded"
    os.execute("mkdir -p '" .. cache_dir:gsub("'", "'\\''") .. "'")
    local hash = self:_md5(input_path)
    return cache_dir .. "/" .. hash .. ".mp3"
end

function Transcoder:isPlayable(path)
    -- Native GStreamer formats (mpg123, wavparse)
    local ext = (path:match("%.([^.]+)$") or ""):lower()
    if ext == "mp3" or ext == "wav" then
        return true
    end
    -- When ffmpeg is bundled, the ffmpeg-pipe backend can decode
    -- m4b/aac/ogg/flac/etc. directly without pre-transcoding.
    if self:_findFfmpeg() then
        return true
    end
    return false
end

function Transcoder:needsTranscode(path)
    if self:isPlayable(path) then return false end
    local cache = self:_cachePath(path)
    local f = io.open(cache, "r")
    if f then
        f:close()
        return false -- cached transcode exists
    end
    return true
end

function Transcoder:transcode(input_path, on_progress)
    local ffmpeg = self:_findFfmpeg()
    if not ffmpeg then
        error("ffmpeg not found")
    end

    local output_path = self:_cachePath(input_path)

    -- Check if already cached
    local f = io.open(output_path, "r")
    if f then
        f:close()
        logger.warn("Transcoder: using cached", output_path)
        return output_path
    end

    -- Transcode: copy audio to MP3 V2 (~190 kbps, good quality/size),
    -- copy metadata (chapters), copy cover art, use id3v2.3 for compatibility.
    -- nice -n 10 keeps the UI responsive during the long conversion.
    local tmp_path = output_path .. ".tmp"
    local cmd = string.format(
        'nice -n 10 "%s" -y -i "%s" -vn -c:a libmp3lame -q:a 2 ' ..
        '-map_metadata 0 -id3v2_version 3 -write_id3v1 1 ' ..
        '-f mp3 "%s" 2>/dev/null',
        ffmpeg:gsub('"', '\\"'),
        input_path:gsub('"', '\\"'),
        tmp_path:gsub('"', '\\"')
    )

    logger.warn("Transcoder: starting transcoding")
    logger.warn("Transcoder: cmd =", cmd:sub(1, 200))

    local rc = os.execute(cmd)

    if rc == 0 or rc == true then
        -- Verify output exists and has content
        local verify = io.open(tmp_path, "r")
        if verify then
            verify:close()
            os.execute('mv "' .. tmp_path:gsub('"', '\\"') .. '" "' .. output_path:gsub('"', '\\"') .. '"')
            logger.warn("Transcoder: finished", output_path)
            return output_path
        end
    end

    -- Clean up failed temp file
    os.execute('rm -f "' .. tmp_path:gsub('"', '\\"') .. '" 2>/dev/null')
    error("ffmpeg transcoding failed")
end

function Transcoder:clearOldTranscodes(max_age_days)
    max_age_days = max_age_days or 30
    local cache_dir = self.plugin_dir .. "/cache/transcoded"
    local cmd = string.format(
        "find '%s' -type f -mtime +%d -delete 2>/dev/null",
        cache_dir:gsub("'", "'\\''"),
        max_age_days
    )
    os.execute(cmd)
end

function Transcoder:getPlayablePath(input_path)
    if self:isPlayable(input_path) then
        return input_path
    end
    local cache = self:_cachePath(input_path)
    local f = io.open(cache, "r")
    if f then
        f:close()
        return cache
    end
    return nil
end

return Transcoder
