--[[--
SessionRecorder -- Record audiobook/TTS sessions for debugging and sharing.

Captures:
- Audio produced by the plugin (TTS WAV files, decoded playback audio).
- Actual video of the screen by spawning ffmpeg against /dev/fb0.
- Sparse framebuffer screenshots as a fallback when video capture is unavailable.
- Optional touch gestures inside the plugin's own widgets.

Output is a timestamped folder with events.jsonl, manifest.json, video.avi,
audio/, and screenshots/. When recording stops, a dialog shows the folder path.

@module koplugin.audiobook.sessionrecorder
--]]

local logger = require("logger")
local _ = require("audiobook_gettext")
local T = require("ffi/util").template

-- These are loaded lazily inside init() to avoid failures at module load time.
local Device, UIManager, InfoMessage, JSON, lfs

local SessionRecorder = {}

function SessionRecorder:new(o)
    o = o or {}
    setmetatable(o, self)
    self.__index = self
    o._recording = false
    o._session_dir = nil
    o._events_file = nil
    o._last_frame_hash = nil
    o._last_frame_file = nil
    o._last_frame_time = nil
    o._frame_hold_start = nil
    o._screenshot_count = 0
    o._audio_count = 0
    o._event_count = 0
    o._scheduled_screenshot = nil
    o._shot_supported = false
    o._ffmpeg_path = nil
    o._fbdev_available = false
    o._video_pid = nil
    o._video_captured = false
    o._video_fallback = false
    o._plugin_dir = o.plugin_dir or "."
    return o
end

function SessionRecorder:init()
    local ok, err = pcall(function()
        Device = require("device")
        UIManager = require("ui/uimanager")
        InfoMessage = require("ui/widget/infomessage")
        JSON = require("json")
        lfs = require("libs/libkoreader-lfs")
    end)
    if not ok then
        logger.warn("SessionRecorder: failed to load UI modules:", err)
        return false
    end

    self._shot_supported = (Device.screen.shot ~= nil)
    self._hash_available = self:_hashAvailable()
    self._ffmpeg_path = self:_findFfmpeg()
    self._fbdev_available = self:_fbdevAvailable()
    return true
end

-- ---------------------------------------------------------------------------
-- Platform / utility helpers
-- ---------------------------------------------------------------------------

function SessionRecorder:_platformRoot()
    -- Prefer KOReader's full data directory when available; it is always on
    -- user-accessible storage and resolves relative paths like ".".
    local datastorage_ok, datastorage = pcall(require, "datastorage")
    if datastorage_ok and datastorage and datastorage.getFullDataDir then
        local data_dir = datastorage:getFullDataDir()
        if data_dir and data_dir ~= "" then
            return data_dir
        end
    end
    if datastorage_ok and datastorage and datastorage.getDataDir then
        local data_dir = datastorage.getDataDir()
        if data_dir and data_dir ~= "" then
            return data_dir
        end
    end
    if Device:isKobo() then
        return "/mnt/onboard"
    elseif Device:isKindle() then
        return "/mnt/us"
    elseif Device:isPocketBook() then
        return "/mnt/ext1"
    elseif Device:isAndroid() then
        return "/sdcard"
    end
    return "/tmp"
end

function SessionRecorder:_sanitizePath(path)
    path = path or ""
    path = path:gsub("/home/[^/]+/", "/home/<user>/")
    path = path:gsub("/Users/[^/]+/", "/Users/<user>/")
    path = path:gsub("/storage/emulated/%d+/", "/sdcard/")
    return path
end

function SessionRecorder:_commandSuccess(status)
    -- Lua 5.1 os.execute returns a number (0 = success); Lua 5.2+ returns boolean.
    if status == true or status == 0 then return true end
    return false
end

function SessionRecorder:_ensureDir(path)
    local status = os.execute('mkdir -p "' .. path:gsub('"', '\\"') .. '" 2>/dev/null')
    return self:_commandSuccess(status)
end

function SessionRecorder:_hashFile(path)
    local handle = io.popen('md5sum "' .. path:gsub('"', '\\"') .. '" 2>/dev/null')
    if not handle then return nil end
    local out = handle:read("*l") or ""
    handle:close()
    return out:match("^(%x+)")
end

function SessionRecorder:_hashAvailable()
    local h = io.popen("md5sum /dev/null 2>/dev/null")
    if not h then return false end
    local out = h:read("*l") or ""
    h:close()
    return out:match("^(%x+)") ~= nil
end

function SessionRecorder:_findFfmpeg()
    -- Probe for ffmpeg in the plugin's bin/ directory or PATH.
    -- Release zips may ship ELF binaries with a .bin extension so they survive
    -- Windows zip extractors; rename .bin back to the original name if needed.
    if self.plugin and self.plugin.path then
        local plugin_ffmpeg = self.plugin.path .. "/bin/ffmpeg"
        local bin_path = plugin_ffmpeg .. ".bin"
        local b = io.open(bin_path, "r")
        if b then
            b:close()
            os.remove(plugin_ffmpeg)
            local ok, err = os.rename(bin_path, plugin_ffmpeg)
            if ok then
                logger.warn("SessionRecorder: renamed", bin_path, "to", plugin_ffmpeg)
            else
                logger.warn("SessionRecorder: failed to rename", bin_path, ":", err)
                return bin_path
            end
        end
        local f = io.open(plugin_ffmpeg, "r")
        if f then
            f:close()
            return plugin_ffmpeg
        end
    end
    local h = io.popen("command -v ffmpeg 2>/dev/null")
    if h then
        local result = h:read("*l")
        h:close()
        if result and result ~= "" then return result end
    end
    return nil
end

function SessionRecorder:_fbdevAvailable()
    local f = io.open("/dev/fb0", "rb")
    if f then
        f:close()
        return true
    end
    return false
end

function SessionRecorder:_videoFps()
    local setting = self.plugin and self.plugin:getSetting("session_recorder_video_fps", 1)
    local fps = tonumber(setting) or 1
    if fps < 1 then fps = 1 end
    if fps > 5 then fps = 5 end
    return fps
end

function SessionRecorder:_videoScale()
    local setting = self.plugin and self.plugin:getSetting("session_recorder_video_scale", 0.5)
    local scale = tonumber(setting) or 0.5
    if scale < 0.25 then scale = 0.25 end
    if scale > 1.0 then scale = 1.0 end
    return scale
end

function SessionRecorder:_videoQuality()
    local setting = self.plugin and self.plugin:getSetting("session_recorder_video_quality", 8)
    local q = tonumber(setting) or 8
    if q < 2 then q = 2 end
    if q > 31 then q = 31 end
    return q
end

function SessionRecorder:_videoIncludeAudio()
    -- ALSA capture is unreliable on e-ink devices; force audio muxing off
    -- until a proper audio source is implemented.
    return false
end

function SessionRecorder:_saveSeparateAudio()
    local setting = self.plugin and self.plugin:getSetting("session_recorder_save_separate_audio", true)
    return setting and true or false
end

function SessionRecorder:_videoFilter()
    -- KOReader may report a rotation mode even though the raw /dev/fb0 memory
    -- is in native panel orientation.  The recorder needs to rotate the
    -- captured stream to match what the user actually sees.
    local rotation = 0
    if Device.screen and Device.screen.getRotationMode then
        rotation = Device.screen:getRotationMode() or 0
    end

    local scale = self:_videoScale()
    local scale_expr = string.format("iw*%g:-1", scale)

    local filters = {}
    table.insert(filters, "scale=" .. scale_expr)

    -- LinuxFB rotation: 0=UR, 1=CW(90), 2=UD(180), 3=CCW(270)
    if rotation == 1 then
        table.insert(filters, "transpose=clock")
    elseif rotation == 2 then
        table.insert(filters, "hflip,vflip")
    elseif rotation == 3 then
        table.insert(filters, "transpose=cclock")
    end

    return table.concat(filters, ",")
end

function SessionRecorder:_writeEvent(event)
    if not self._events_file then return end
    event.t = event.t or os.time()
    local ok, line = pcall(JSON.encode, event)
    if not ok then
        logger.warn("SessionRecorder: failed to encode event:", line)
        return
    end
    self._events_file:write(line, "\n")
    self._events_file:flush()
    self._event_count = self._event_count + 1
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

function SessionRecorder:isRecording()
    if not self._recording then
        self:_checkResume()
    end
    return self._recording
end

-- Lazily check for an orphaned ffmpeg process from a previous recorder
-- instance (e.g. after KOReader recreates the plugin on document open) and
-- reattach.  This is called from isRecording() so the menu label stays
-- correct even when the plugin widget is recreated.
function SessionRecorder:_checkResume()
    if self._recording then return end
    self:_resumeVideoCapture()
end

-- Check for an orphaned ffmpeg process from a previous recorder instance
-- (e.g. after KOReader recreates the plugin on document open) and reattach.
function SessionRecorder:_resumeVideoCapture()
    local last_dir = self.plugin and self.plugin:getSetting("session_recorder_last_dir", nil)
    if not last_dir then return false end

    local pid_path = last_dir .. "/.video.pid"
    local pid_f = io.open(pid_path, "r")
    if not pid_f then return false end
    local pid = pid_f:read("*l")
    pid_f:close()
    pid = tonumber(pid)
    if not pid then return false end

    -- Verify the process is still running.
    local proc_check = io.open("/proc/" .. pid, "r")
    if not proc_check then
        -- Clean up stale PID file.
        os.remove(pid_path)
        return false
    end
    proc_check:close()

    -- Reattach to the running session.
    self._session_dir = last_dir
    self._video_pid = pid
    self._video_captured = true
    self._video_fallback = false
    self._recording = true

    -- Restore counters so the manifest is accurate after resume.
    self._screenshot_count = 0
    self._audio_count = 0
    self._event_count = 0

    -- Reopen the event log for appending.
    local events_path = last_dir .. "/events.jsonl"
    local f = io.open(events_path, "a")
    if f then
        self._events_file = f
    end

    -- Re-create the audio directory so the mediaengine WAV tee has a place
    -- to write playback.wav even after the plugin widget was recreated.
    self:_ensureDir(last_dir .. "/audio")

    logger.warn("SessionRecorder: resumed video capture, pid", pid, "dir", last_dir)
    return true
end

function SessionRecorder:start()
    if self._recording then
        logger.warn("SessionRecorder: already recording")
        return false
    end
    if not UIManager then
        logger.warn("SessionRecorder: not initialized")
        return false
    end

    -- Reattach to an existing recording if one is still running.
    if self:_resumeVideoCapture() then
        return true
    end

    local platform_root = self:_platformRoot()
    local stamp = os.date("%Y-%m-%d_%H-%M-%S")
    self._session_dir = platform_root .. "/audiobook-sessions/" .. stamp
    if not self:_ensureDir(self._session_dir) then
        logger.err("SessionRecorder: failed to create session dir:", self._session_dir)
        UIManager:show(InfoMessage:new{
            text = _("Could not create session recording folder."),
            timeout = 5,
        })
        self._session_dir = nil
        return false
    end

    local events_path = self._session_dir .. "/events.jsonl"
    local f, err = io.open(events_path, "w")
    if not f then
        logger.err("SessionRecorder: failed to open events file:", err)
        UIManager:show(InfoMessage:new{
            text = _("Could not open session event log."),
            timeout = 5,
        })
        self._session_dir = nil
        return false
    end
    self._events_file = f

    self._recording = true
    self._screenshot_count = 0
    self._audio_count = 0
    self._event_count = 0
    self._last_frame_hash = nil
    self._last_frame_file = nil
    self._last_frame_time = nil
    self._frame_hold_start = nil
    self._video_pid = nil
    self._video_captured = false
    self._video_fallback = false

    self:_writeEvent({type = "session_start", path = self._session_dir})

    UIManager:show(InfoMessage:new{
        text = _("Session recording is starting.\n\nIt will stop automatically when the screen locks or the device turns off. You can also stop it from the Diagnostics menu."),
        timeout = 3,
    })

    -- Try real-time video capture first; fall back to sparse screenshots.
    if not self:_startVideoCapture() then
        self._video_fallback = true
        self:_scheduleScreenshot(0.5)
    end

    if self.plugin then
        self.plugin:setSetting("session_recorder_last_dir", self._session_dir)
    end

    logger.warn("SessionRecorder: started session at", self._session_dir)
    return true
end

function SessionRecorder:stop()
    if not self._recording then return nil end

    self._recording = false
    if self._scheduled_screenshot then
        UIManager:unschedule(self._scheduled_screenshot)
        self._scheduled_screenshot = nil
    end

    -- Stop real-time video capture (if running) before finalizing the log.
    self:_stopVideoCapture()

    -- If we captured video and there is playback audio, mux them into a
    -- single file with sound.
    if self._video_captured then
        self:_muxAudioIntoVideo()
    end

    -- Flush any pending frame hold from the screenshot fallback.
    self:_flushFrameHold()

    self:_writeEvent({type = "session_stop"})

    if self._events_file then
        self._events_file:close()
        self._events_file = nil
    end

    self:_saveManifest()

    local path = self._session_dir
    local audio_count = self._audio_count
    local video_captured = self._video_captured
    local video_fallback = self._video_fallback
    self._session_dir = nil
    self._last_frame_hash = nil
    self._last_frame_file = nil
    self._last_frame_time = nil
    self._frame_hold_start = nil
    self._video_pid = nil
    self._video_captured = false
    self._video_fallback = false

    -- Clear the last-dir marker so a future start() does not try to resume
    -- a session that has already been stopped.
    if self.plugin then
        self.plugin:setSetting("session_recorder_last_dir", nil)
    end

    logger.warn("SessionRecorder: stopped session at", path)

    self:_showStopDialog(path, video_captured, video_fallback, audio_count)
    return path
end

function SessionRecorder:registerAudioFile(src_path, role)
    if not self._recording then
        -- The plugin widget may have been recreated on document open; try to
        -- reattach to the running session before deciding we are not recording.
        self:_checkResume()
    end
    if not self._recording or not src_path then return false end
    if not role then role = "audio" end
    if not self:_saveSeparateAudio() then return false end

    local lfs_ok = lfs and true
    local src_mode = lfs_ok and lfs.attributes(src_path, "mode") or "file"
    if src_mode ~= "file" then
        logger.warn("SessionRecorder: audio source not found:", src_path)
        return false
    end

    self:_ensureDir(self._session_dir .. "/audio")
    self._audio_count = self._audio_count + 1
    local dest_name = string.format("%s_%04d.wav", role, self._audio_count)
    local dest_path = self._session_dir .. "/audio/" .. dest_name

    -- Try a hard link first (cheap), fall back to copy.
    local linked = self:_commandSuccess(os.execute('ln "' .. src_path:gsub('"', '\\"') .. '" "' .. dest_path:gsub('"', '\\"') .. '" 2>/dev/null'))
    if not linked then
        local copied = self:_commandSuccess(os.execute('cp "' .. src_path:gsub('"', '\\"') .. '" "' .. dest_path:gsub('"', '\\"') .. '" 2>/dev/null'))
        if not copied then
            logger.warn("SessionRecorder: failed to copy audio file:", src_path)
            return false
        end
    end

    self:_writeEvent({type = "audio", role = role, file = "audio/" .. dest_name})
    logger.dbg("SessionRecorder: registered audio", role, dest_path)
    return true
end

function SessionRecorder:recordGesture(ges, source_widget)
    if not self._recording or not ges then return end
    self:_writeEvent({
        type = "gesture",
        widget = source_widget or "unknown",
        ges = ges.ges or "unknown",
        x = ges.pos and ges.pos.x or nil,
        y = ges.pos and ges.pos.y or nil,
    })
end

function SessionRecorder:recordEvent(event_type, data)
    if not self._recording then return end
    local event = {type = event_type}
    if data then
        for k, v in pairs(data) do
            event[k] = v
        end
    end
    self:_writeEvent(event)
end

-- ---------------------------------------------------------------------------
-- Screenshots
-- ---------------------------------------------------------------------------

function SessionRecorder:_scheduleScreenshot(delay)
    if not self._recording then return end
    delay = delay or self:_screenshotPollInterval()
    local function cb()
        self._scheduled_screenshot = nil
        self:_captureFrame()
        self:_scheduleScreenshot()
    end
    self._scheduled_screenshot = cb
    UIManager:scheduleIn(delay, cb)
end

function SessionRecorder:_screenshotInterval()
    -- Maximum gap between saved frames when the screen is static.
    local setting = self.plugin and self.plugin:getSetting("session_recorder_max_interval_s", 5)
    return tonumber(setting) or 5
end

function SessionRecorder:_screenshotPollInterval()
    -- How often we check the framebuffer for changes.
    return 1.0
end

function SessionRecorder:_captureFrame()
    if not self._recording then return end
    if not self._shot_supported then
        return
    end

    local temp_path = self._session_dir .. "/.last_frame.tmp.png"
    local ok = pcall(function() Device.screen:shot(temp_path) end)
    if not ok then
        logger.warn("SessionRecorder: screenshot capture failed")
        return
    end

    local hash = self:_hashFile(temp_path)
    if not hash and self._hash_available then
        -- Hashing should work but failed for this file; drop it and try again.
        os.remove(temp_path)
        return
    end

    local now = os.time()
    local max_interval = self:_screenshotInterval()
    local force_save = false
    if self._last_frame_time and (now - self._last_frame_time) >= max_interval then
        force_save = true
    end

    if hash and hash == self._last_frame_hash and not force_save then
        -- No change; extend the hold and remove the temp file.
        os.remove(temp_path)
        if not self._frame_hold_start then
            self._frame_hold_start = now
        end
        return
    end

    -- Screen changed or max interval reached.
    self:_flushFrameHold()

    self:_ensureDir(self._session_dir .. "/screenshots")
    self._screenshot_count = self._screenshot_count + 1
    local filename = string.format("%04d.png", self._screenshot_count)
    local dest_path = self._session_dir .. "/screenshots/" .. filename

    os.rename(temp_path, dest_path)

    self._last_frame_hash = hash
    self._last_frame_file = "screenshots/" .. filename
    self._last_frame_time = now
    self._frame_hold_start = nil

    self:_writeEvent({type = "screenshot", file = self._last_frame_file})
    logger.dbg("SessionRecorder: screenshot", filename)
end

function SessionRecorder:_flushFrameHold()
    if self._frame_hold_start and self._last_frame_file then
        local duration = os.time() - self._frame_hold_start
        if duration > 0 then
            self:_writeEvent({
                type = "frame_hold",
                duration_s = duration,
                last_frame = self._last_frame_file,
            })
        end
    end
    self._frame_hold_start = nil
end

-- ---------------------------------------------------------------------------
-- Video capture (real-time via ffmpeg + fbdev)
-- ---------------------------------------------------------------------------

function SessionRecorder:_startVideoCapture()
    if not self._ffmpeg_path or not self._fbdev_available then
        logger.warn("SessionRecorder: video capture not available (ffmpeg:", self._ffmpeg_path, ", fbdev:", self._fbdev_available, ")")
        return false
    end
    if not self._session_dir then return false end

    local fps = self:_videoFps()
    local quality = self:_videoQuality()
    local include_audio = self:_videoIncludeAudio()
    local vf = self:_videoFilter()
    local video_path = self._session_dir .. "/video.avi"
    local pid_path = self._session_dir .. "/.video.pid"

    -- Optionally mux ALSA audio into the same file.  All input options must
    -- come before the output file; ffmpeg rejects -vf after a second -i.
    local cmd_parts = {
        string.format('"%s" -y', self._ffmpeg_path:gsub('"', '\\"')),
        string.format('-f fbdev -framerate %d -i /dev/fb0', fps),
    }
    if include_audio then
        table.insert(cmd_parts, "-f alsa -i default")
    end
    table.insert(cmd_parts, string.format('-vf "%s"', vf))
    table.insert(cmd_parts, string.format('-c:v mjpeg -q:v %d -r %d', quality, fps))
    if include_audio then
        table.insert(cmd_parts, "-c:a aac -b:a 96k")
    end
    table.insert(cmd_parts, string.format('"%s"', video_path:gsub('"', '\\"')))

    local cmd = table.concat(cmd_parts, " ")
        .. string.format(' >/dev/null 2>&1 & echo $! > "%s"', pid_path:gsub('"', '\\"'))

    logger.warn("SessionRecorder: video cmd:", cmd)

    local status = os.execute(cmd)
    if not self:_commandSuccess(status) then
        logger.warn("SessionRecorder: failed to spawn ffmpeg for video capture")
        return false
    end

    -- Give ffmpeg a moment to start and write its PID.
    os.execute("sleep 0.5")

    local pid_f = io.open(pid_path, "r")
    if not pid_f then
        logger.warn("SessionRecorder: ffmpeg started but PID file is missing")
        return false
    end
    local pid = pid_f:read("*l")
    pid_f:close()
    pid = tonumber(pid)
    if not pid then
        logger.warn("SessionRecorder: could not parse ffmpeg PID")
        return false
    end

    -- Verify the process is actually running.
    local proc_check = io.open("/proc/" .. pid, "r")
    if not proc_check then
        logger.warn("SessionRecorder: ffmpeg process", pid, "not running")
        return false
    end
    proc_check:close()

    self._video_pid = pid
    self._video_captured = true
    self:_writeEvent({type = "video_start", file = "video.avi", fps = fps, quality = quality, include_audio = include_audio})
    logger.warn("SessionRecorder: ffmpeg video capture started, pid", pid, "file", video_path)
    return true
end

function SessionRecorder:_stopVideoCapture()
    if not self._video_pid then return end
    local pid = self._video_pid
    local video_path = self._session_dir .. "/video.avi"

    -- SIGINT asks ffmpeg to finalize the container gracefully.
    os.execute("kill -INT " .. pid .. " 2>/dev/null")

    -- Wait up to 3 seconds for the process to exit.
    for _ = 1, 6 do
        os.execute("sleep 0.5")
        local f = io.open("/proc/" .. pid, "r")
        if not f then break end
        f:close()
    end

    -- Escalate if still alive.
    os.execute("kill -TERM " .. pid .. " 2>/dev/null")
    os.execute("sleep 0.2")
    os.execute("kill -KILL " .. pid .. " 2>/dev/null")

    self._video_pid = nil

    -- Verify the video file exists and is non-empty.
    local f = io.open(video_path, "rb")
    if f then
        local size = f:seek("end")
        f:close()
        if size and size > 0 then
            logger.warn("SessionRecorder: video file size", size)
            self:_writeEvent({type = "video_stop", file = "video.avi", size = size})
        else
            logger.warn("SessionRecorder: video file is empty")
            self._video_captured = false
        end
    else
        logger.warn("SessionRecorder: video file not found")
        self._video_captured = false
    end
end

-- Mux any captured playback audio into video.avi after recording stops.
-- The Kobo has no usable ALSA capture device, so we cannot mux audio
-- in real time.  The mediaengine ffmpeg-pipe backend writes a
-- playback.wav alongside the video; we merge them here.
function SessionRecorder:_muxAudioIntoVideo()
    if not self._session_dir or not self._ffmpeg_path then return end
    if not self:_saveSeparateAudio() then return end
    local video_path = self._session_dir .. "/video.avi"
    local audio_path = self._session_dir .. "/audio/playback.wav"
    local output_path = self._session_dir .. "/video_with_audio.avi"

    -- Check that both files exist and are non-empty.
    local vf = io.open(video_path, "rb")
    if not vf then return end
    local vsize = vf:seek("end")
    vf:close()
    if not vsize or vsize == 0 then return end

    local af = io.open(audio_path, "rb")
    if not af then return end
    local asize = af:seek("end")
    af:close()
    if not asize or asize == 0 then return end

    local cmd = string.format(
        '"%s" -y -i "%s" -i "%s" -c:v copy -c:a aac -b:a 96k -shortest "%s" >/dev/null 2>&1',
        self._ffmpeg_path:gsub('"', '\\"'),
        video_path:gsub('"', '\\"'),
        audio_path:gsub('"', '\\"'),
        output_path:gsub('"', '\\"')
    )

    local status = os.execute(cmd)
    if self:_commandSuccess(status) then
        local of = io.open(output_path, "rb")
        if of then
            local osize = of:seek("end")
            of:close()
            if osize and osize > 0 then
                logger.warn("SessionRecorder: muxed video+audio size", osize)
                self:_writeEvent({type = "video_muxed", file = "video_with_audio.avi", size = osize})
            end
        end
    else
        logger.warn("SessionRecorder: failed to mux audio into video")
    end
end

-- ---------------------------------------------------------------------------
-- Manifest
-- ---------------------------------------------------------------------------

function SessionRecorder:_saveManifest()
    if not self._session_dir then return end
    local manifest = {
        created_at = os.date("%Y-%m-%dT%H:%M:%S"),
        platform = (Device.getPlatform and Device:getPlatform()) or (Device.platform or "unknown"),
        model = (Device.getDeviceModel and Device:getDeviceModel()) or (Device.model or "unknown"),
        screenshot_count = self._screenshot_count,
        audio_count = self._audio_count,
        event_count = self._event_count,
        shot_supported = self._shot_supported,
        video_captured = self._video_captured,
        video_fallback = self._video_fallback,
    }
    local path = self._session_dir .. "/manifest.json"
    local f = io.open(path, "w")
    if f then
        local ok, json_str = pcall(JSON.encode, manifest)
        if ok then
            f:write(json_str)
        end
        f:close()
    end
end

function SessionRecorder:_showStopDialog(path, video_captured, video_fallback, audio_count)
    if not UIManager then return end

    -- Build a concise file list instead of embedding the full path in the
    -- dialog title (very long paths make ButtonDialog's width computation
    -- fail on KOReader).
    local files = {}
    if video_captured then
        table.insert(files, "video.avi")
        -- Mention the muxed version if it was produced.
        local muxed = io.open(path .. "/video_with_audio.avi", "rb")
        if muxed then
            muxed:close()
            table.insert(files, "video_with_audio.avi")
        end
    elseif video_fallback then
        table.insert(files, "screenshots/")
    end

    -- List actual audio files so the user sees what was really captured.
    local audio_files = {}
    local audio_dir = path .. "/audio"
    local lfs_ok, lfs_mod = pcall(require, "libs/libkoreader-lfs")
    if lfs_ok and lfs_mod then
        local ok, iter, state = pcall(lfs_mod.dir, audio_dir)
        if ok and iter then
            for entry in iter, state do
                if entry ~= "." and entry ~= ".." then
                    table.insert(audio_files, "audio/" .. entry)
                end
            end
        end
    end
    if #audio_files > 0 then
        table.insert(files, table.concat(audio_files, ", "))
    elseif audio_count and audio_count > 0 then
        table.insert(files, "audio/")
    else
        table.insert(files, "no audio captured")
    end

    table.insert(files, "events.jsonl")
    table.insert(files, "manifest.json")

    local file_summary = table.concat(files, ", ")
    local text = T(_("Session recording saved.\n\nFolder: %1\n\nContents: %2"), path, file_summary)

    -- Use an InfoMessage (auto-sizing) instead of a ButtonDialog with a long
    -- title, because ButtonDialog computes its width from the button table
    -- and a long title can produce an invalid width.
    UIManager:show(InfoMessage:new{
        text = text,
        timeout = 10,
    })
end

return SessionRecorder
