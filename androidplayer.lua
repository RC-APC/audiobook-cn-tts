--[[--
Android MediaPlayer for audiobook / EPUB Media Overlay playback.

Creates android.media.MediaPlayer directly via JNI — no tts_helper.dex and
no bundled ffmpeg.  The glibc ffmpeg shipped in the plugin SIGSEGVs on
Android (Bionic), which was crashing KOReader on "Play aligned audiobook".

@module androidplayer
--]]

local ffi = require("ffi")
local logger = require("logger")
local UIManager = require("ui/uimanager")
local time = require("ui/time")

local AndroidPlayer = {}

local function checkException(env)
    if env[0].ExceptionCheck(env) ~= 0 then
        env[0].ExceptionDescribe(env)
        env[0].ExceptionClear(env)
        return true
    end
    return false
end

local function getMethod(env, clazz, name, sig)
    local mid = env[0].GetMethodID(env, clazz, name, sig)
    if checkException(env) or mid == nil then return nil end
    local ok, nullish = pcall(function()
        return tonumber(ffi.cast("intptr_t", mid)) == 0
    end)
    if ok and nullish then return nil end
    return mid
end

local function getStaticMethod(env, clazz, name, sig)
    local mid = env[0].GetStaticMethodID(env, clazz, name, sig)
    if checkException(env) or mid == nil then return nil end
    local ok, nullish = pcall(function()
        return tonumber(ffi.cast("intptr_t", mid)) == 0
    end)
    if ok and nullish then return nil end
    return mid
end

function AndroidPlayer:new(o)
    o = o or {}
    setmetatable(o, self)
    self.__index = self
    o._android = nil
    o._mp_ref = nil
    o._mp_class = nil
    o._method = {}
    o._initialized = false
    o._duration_ms = 0
    o._playing = false
    o._paused = false
    o._start_seek_ms = 0
    o._wall_start = nil
    o._pause_accum_ms = 0
    o._pause_wall_start = nil
    o._ever_confirmed_playing = false
    o._last_mp_pos_ms = 0
    o._audio_started = false
    o._mp_baseline_ms = nil
    o._mp_stuck_reads = 0
    o._volume = 1.0
    o._speed = 1.0
    o._eos_reached_at = nil
    return o
end

function AndroidPlayer:init()
    if self._initialized then return true end

    local Device = require("device")
    if not (Device.isAndroid and Device:isAndroid()) then
        return false
    end

    local ok, android = pcall(require, "android")
    if not ok or not android then
        logger.err("AndroidPlayer: cannot load android module")
        return false
    end
    self._android = android

    local load_ok = false
    android.jni:context(android.app.activity.vm, function(jni)
        local env = jni.env
        local mp_class = env[0].FindClass(env, "android/media/MediaPlayer")
        if checkException(env) or mp_class == nil then
            logger.err("AndroidPlayer: MediaPlayer class not found")
            return
        end

        self._method.init = getMethod(env, mp_class, "<init>", "()V")
        self._method.setDataSource = getMethod(env, mp_class,
            "setDataSource", "(Ljava/lang/String;)V")
        self._method.prepare = getMethod(env, mp_class, "prepare", "()V")
        self._method.start = getMethod(env, mp_class, "start", "()V")
        self._method.pause = getMethod(env, mp_class, "pause", "()V")
        self._method.stop = getMethod(env, mp_class, "stop", "()V")
        self._method.reset = getMethod(env, mp_class, "reset", "()V")
        self._method.release = getMethod(env, mp_class, "release", "()V")
        self._method.seekTo = getMethod(env, mp_class, "seekTo", "(I)V")
        self._method.isPlaying = getMethod(env, mp_class, "isPlaying", "()Z")
        self._method.getCurrentPosition = getMethod(env, mp_class,
            "getCurrentPosition", "()I")
        self._method.getDuration = getMethod(env, mp_class, "getDuration", "()I")
        self._method.setAudioAttributes = getMethod(env, mp_class,
            "setAudioAttributes", "(Landroid/media/AudioAttributes;)V")
        self._method.setVolume = getMethod(env, mp_class,
            "setVolume", "(FF)V")
        -- API 23+: live speed via PlaybackParams (pitch stays 1.0).
        self._method.getPlaybackParams = getMethod(env, mp_class,
            "getPlaybackParams", "()Landroid/media/PlaybackParams;")
        self._method.setPlaybackParams = getMethod(env, mp_class,
            "setPlaybackParams", "(Landroid/media/PlaybackParams;)V")
        local pp_class = env[0].FindClass(env, "android/media/PlaybackParams")
        if pp_class and not checkException(env) then
            self._method.ppSetSpeed = getMethod(env, pp_class,
                "setSpeed", "(F)Landroid/media/PlaybackParams;")
            self._method.ppSetPitch = getMethod(env, pp_class,
                "setPitch", "(F)Landroid/media/PlaybackParams;")
            self._pp_class = env[0].NewGlobalRef(env, pp_class)
            env[0].DeleteLocalRef(env, pp_class)
        else
            checkException(env)
            logger.warn("AndroidPlayer: PlaybackParams unavailable")
        end

        if not self._method.init
            or not self._method.setDataSource
            or not self._method.prepare
            or not self._method.start
            or not self._method.seekTo
            or not self._method.getCurrentPosition then
            logger.err("AndroidPlayer: required MediaPlayer methods missing")
            env[0].DeleteLocalRef(env, mp_class)
            return
        end

        -- USAGE_MEDIA + CONTENT_TYPE_SPEECH: narration mixes more cleanly with
        -- background music (Spotify) than CONTENT_TYPE_MUSIC on many devices.
        self._attrs_ref = nil
        local aa_class = env[0].FindClass(env, "android/media/AudioAttributes")
        local builder_class = env[0].FindClass(env,
            "android/media/AudioAttributes$Builder")
        if aa_class and builder_class and not checkException(env) then
            local b_init = getMethod(env, builder_class, "<init>", "()V")
            local set_usage = getMethod(env, builder_class,
                "setUsage", "(I)Landroid/media/AudioAttributes$Builder;")
            local set_ctype = getMethod(env, builder_class,
                "setContentType", "(I)Landroid/media/AudioAttributes$Builder;")
            local build = getMethod(env, builder_class,
                "build", "()Landroid/media/AudioAttributes;")
            -- USAGE_MEDIA=1, CONTENT_TYPE_SPEECH=1
            if b_init and set_usage and set_ctype and build then
                local builder = env[0].NewObject(env, builder_class, b_init)
                if builder and not checkException(env) then
                    local args = ffi.new("jvalue[1]")
                    args[0].i = 1  -- USAGE_MEDIA
                    builder = env[0].CallObjectMethodA(env, builder, set_usage, args)
                    checkException(env)
                    args[0].i = 1  -- CONTENT_TYPE_SPEECH
                    builder = env[0].CallObjectMethodA(env, builder, set_ctype, args)
                    checkException(env)
                    local attrs = env[0].CallObjectMethod(env, builder, build)
                    if attrs and not checkException(env) then
                        self._attrs_ref = env[0].NewGlobalRef(env, attrs)
                        env[0].DeleteLocalRef(env, attrs)
                    end
                    if builder then env[0].DeleteLocalRef(env, builder) end
                end
            end
            env[0].DeleteLocalRef(env, aa_class)
            env[0].DeleteLocalRef(env, builder_class)
        else
            checkException(env)
        end

        self._mp_class = env[0].NewGlobalRef(env, mp_class)
        env[0].DeleteLocalRef(env, mp_class)
        load_ok = true
    end)

    if not load_ok then return false end
    self._initialized = true
    logger.warn("AndroidPlayer: ready (direct MediaPlayer, no dex)")
    return true
end

function AndroidPlayer:_releasePlayer()
    if not self._mp_ref then return end
    local android = self._android
    local mp = self._mp_ref
    self._mp_ref = nil
    self._playing = false
    self._paused = false
    self._audio_started = false
    self._mp_baseline_ms = nil
    self._mp_stuck_reads = 0
    android.jni:context(android.app.activity.vm, function(jni)
        local env = jni.env
        pcall(function()
            if self._method.reset then
                env[0].CallVoidMethod(env, mp, self._method.reset)
                checkException(env)
            end
            if self._method.release then
                env[0].CallVoidMethod(env, mp, self._method.release)
                checkException(env)
            end
        end)
        env[0].DeleteGlobalRef(env, mp)
    end)
end

--- Play a local file.  Optional seek_ms applied after prepare.
--- @return boolean success
function AndroidPlayer:play(path, seek_ms)
    if not self._initialized then return false end
    seek_ms = math.floor(tonumber(seek_ms) or 0)
    self:_releasePlayer()

    local android = self._android
    local ok = false
    local duration_ms = 0

    android.jni:context(android.app.activity.vm, function(jni)
        local env = jni.env
        local mp = env[0].NewObject(env, self._mp_class, self._method.init)
        if checkException(env) or mp == nil then
            logger.err("AndroidPlayer: MediaPlayer() failed")
            return
        end

        if self._attrs_ref and self._method.setAudioAttributes then
            env[0].CallVoidMethod(env, mp, self._method.setAudioAttributes,
                self._attrs_ref)
            checkException(env)
        end

        local j_path = env[0].NewStringUTF(env, path)
        env[0].CallVoidMethod(env, mp, self._method.setDataSource, j_path)
        env[0].DeleteLocalRef(env, j_path)
        if checkException(env) then
            logger.err("AndroidPlayer: setDataSource failed for", path)
            env[0].CallVoidMethod(env, mp, self._method.release)
            checkException(env)
            env[0].DeleteLocalRef(env, mp)
            return
        end

        env[0].CallVoidMethod(env, mp, self._method.prepare)
        if checkException(env) then
            logger.err("AndroidPlayer: prepare failed for", path)
            env[0].CallVoidMethod(env, mp, self._method.release)
            checkException(env)
            env[0].DeleteLocalRef(env, mp)
            return
        end

        if self._method.getDuration then
            duration_ms = env[0].CallIntMethod(env, mp, self._method.getDuration)
            checkException(env)
        end

        -- Apply speed after prepare() (required by MediaPlayer) so the first
        -- samples already play at the requested rate.
        self:_applySpeedEnv(env, mp)

        if seek_ms > 50 then
            local sargs = ffi.new("jvalue[1]")
            sargs[0].i = seek_ms
            env[0].CallVoidMethodA(env, mp, self._method.seekTo, sargs)
            checkException(env)
        end

        env[0].CallVoidMethod(env, mp, self._method.start)
        if checkException(env) then
            logger.err("AndroidPlayer: start failed")
            env[0].CallVoidMethod(env, mp, self._method.release)
            checkException(env)
            env[0].DeleteLocalRef(env, mp)
            return
        end

        self._mp_ref = env[0].NewGlobalRef(env, mp)
        env[0].DeleteLocalRef(env, mp)
        self._eos_reached_at = nil
        ok = true
    end)

    if ok then
        self._duration_ms = duration_ms or 0
        self._playing = true
        self._paused = false
        self._start_seek_ms = math.max(0, seek_ms)
        -- UIManager time is real wall-clock; os.clock() is CPU time and barely
        -- advances while KOReader is idle (the Boox timer/highlight bug).
        self._wall_start = UIManager:getTime()
        self._pause_accum_ms = 0
        self._pause_wall_start = nil
        self._ever_confirmed_playing = false
        self._last_mp_pos_ms = self._start_seek_ms
        self._audio_started = false
        self._mp_baseline_ms = nil
        self._mp_stuck_reads = 0
        -- Per-player gain (independent of Android system/stream volume).
        self:setVolume(self._volume or 1.0)
        logger.warn("AndroidPlayer: playing", path,
            "seek_ms=", seek_ms, "duration_ms=", self._duration_ms,
            "volume=", self._volume, "speed=", self._speed)
    end
    return ok
end

--- Per-stream volume 0..1 (MediaPlayer.setVolume).  Does NOT change the
--- Android system/AirPods volume — only this audiobook's gain relative to it.
function AndroidPlayer:setVolume(vol)
    vol = tonumber(vol) or 1.0
    if vol < 0 then vol = 0 end
    if vol > 1 then vol = 1 end
    self._volume = vol
    if not self._mp_ref or not self._method.setVolume then return end
    local android = self._android
    android.jni:context(android.app.activity.vm, function(jni)
        local env = jni.env
        local args = ffi.new("jvalue[2]")
        args[0].f = vol
        args[1].f = vol
        env[0].CallVoidMethodA(env, self._mp_ref, self._method.setVolume, args)
        checkException(env)
    end)
end

--- Apply PlaybackParams.setSpeed on a prepared MediaPlayer (local or global).
--- Pitch is forced to 1.0 so 1.5x is time-stretch, not chipmunk.
function AndroidPlayer:_applySpeedEnv(env, mp)
    if not mp then return false end
    local speed = self._speed or 1.0
    if not self._method.getPlaybackParams
        or not self._method.setPlaybackParams
        or not self._method.ppSetSpeed then
        if math.abs(speed - 1.0) >= 0.01 then
            logger.warn("AndroidPlayer: speed control unavailable; ignoring", speed)
        end
        return false
    end
    local params = env[0].CallObjectMethod(env, mp, self._method.getPlaybackParams)
    if checkException(env) or params == nil then
        logger.warn("AndroidPlayer: getPlaybackParams failed")
        return false
    end
    local args = ffi.new("jvalue[1]")
    args[0].f = speed
    local updated = env[0].CallObjectMethodA(env, params, self._method.ppSetSpeed, args)
    if checkException(env) then
        env[0].DeleteLocalRef(env, params)
        logger.warn("AndroidPlayer: PlaybackParams.setSpeed failed")
        return false
    end
    local to_set = updated or params
    if self._method.ppSetPitch then
        args[0].f = 1.0
        local pitched = env[0].CallObjectMethodA(env, to_set, self._method.ppSetPitch, args)
        if not checkException(env) and pitched then
            to_set = pitched
        end
    end
    env[0].CallVoidMethod(env, mp, self._method.setPlaybackParams, to_set)
    local failed = checkException(env)
    if updated and updated ~= params then
        env[0].DeleteLocalRef(env, updated)
    end
    if to_set and to_set ~= params and to_set ~= updated then
        env[0].DeleteLocalRef(env, to_set)
    end
    env[0].DeleteLocalRef(env, params)
    if failed then
        logger.warn("AndroidPlayer: setPlaybackParams failed speed=", speed)
        return false
    end
    logger.warn("AndroidPlayer: speed=", speed)
    return true
end

--- Playback rate 0.5..3.0.  Live on a running MediaPlayer; stored otherwise.
function AndroidPlayer:setSpeed(speed)
    speed = tonumber(speed) or 1.0
    if speed < 0.5 then speed = 0.5 end
    if speed > 3.0 then speed = 3.0 end
    -- Re-anchor the wall clock at the current *media* position so highlights
    -- keep tracking after a mid-play rate change (wall time is not media time).
    local pos
    if self._playing and self._wall_start then
        pos = self:_wallPositionMs()
    end
    self._speed = speed
    if pos then
        self:_reanchorWallToMs(pos)
        if self._paused then
            self._pause_wall_start = UIManager:getTime()
        end
    end
    if not self._mp_ref or not self._android then return end
    local android = self._android
    local was_active = self._playing and not self._paused
    android.jni:context(android.app.activity.vm, function(jni)
        self:_applySpeedEnv(jni.env, self._mp_ref)
        -- Some OEM MediaPlayer implementations pause on setPlaybackParams.
        if was_active and self._method.start then
            jni.env[0].CallVoidMethod(jni.env, self._mp_ref, self._method.start)
            checkException(jni.env)
        end
    end)
end

function AndroidPlayer:_queryMpPositionMs()
    if not self._mp_ref or not self._method.getCurrentPosition then return nil end
    local android = self._android
    local pos = android.jni:context(android.app.activity.vm, function(jni)
        local p = jni.env[0].CallIntMethod(jni.env,
            self._mp_ref, self._method.getCurrentPosition)
        if checkException(jni.env) then return nil end
        return tonumber(p)
    end)
    if pos == nil then return nil end
    return math.max(0, math.floor(pos))
end

function AndroidPlayer:_reanchorWallToMs(pos_ms)
    pos_ms = math.floor(tonumber(pos_ms) or 0)
    self._wall_start = UIManager:getTime()
    self._start_seek_ms = pos_ms
    self._pause_accum_ms = 0
    self._pause_wall_start = nil
    self._last_mp_pos_ms = pos_ms
end

--- One-shot: wait until audio is actually moving, then lock wall-clock to that
--- position.  After this, sync uses only wall time (monotonic) so highlights
--- never thrash from flaky MediaPlayer.getCurrentPosition() readings.
function AndroidPlayer:_tryLockWallClock(mp)
    if self._audio_started then return true end

    local seek = self._start_seek_ms or 0
    local now = UIManager:getTime()
    local wait_ms = 0
    if self._wall_start then
        wait_ms = time.to_ms(now - self._wall_start) or 0
    end

    if mp ~= nil then
        if self._mp_baseline_ms == nil then
            self._mp_baseline_ms = mp
        end
        local advanced = mp > (self._mp_baseline_ms or 0) + 60
            or mp > seek + 60
        if advanced then
            self._audio_started = true
            self._ever_confirmed_playing = true
            self:_reanchorWallToMs(mp)
            logger.warn("AndroidPlayer: wall locked to MP pos_ms=", mp,
                "after", wait_ms, "ms")
            return true
        end
    end

    -- Boox often reports a stuck seek position over JNI: unlock after a short
    -- grace so highlights still start, slightly late rather than never.
    if wait_ms >= 350 then
        self._audio_started = true
        self._ever_confirmed_playing = true
        self:_reanchorWallToMs(seek)
        logger.warn("AndroidPlayer: wall locked to seek after grace", wait_ms, "ms")
        return true
    end
    return false
end

function AndroidPlayer:_wallPositionMs()
    if not self._wall_start then return self._start_seek_ms or 0 end
    local elapsed
    if self._paused and self._pause_wall_start then
        elapsed = time.to_ms(self._pause_wall_start - self._wall_start)
    else
        elapsed = time.to_ms(UIManager:getTime() - self._wall_start)
    end
    elapsed = (elapsed or 0) - (self._pause_accum_ms or 0)
    -- MediaPlayer speed scales media time vs wall clock.  Highlights use this
    -- position, so elapsed real time must be multiplied by the current rate.
    local speed = self._speed or 1.0
    local pos = (self._start_seek_ms or 0) + math.floor(math.max(0, elapsed) * speed)
    if self._duration_ms and self._duration_ms > 0 then
        pos = math.min(pos, self._duration_ms)
    end
    return math.floor(pos)
end

function AndroidPlayer:pause()
    if not self._mp_ref then return end
    -- Prefer wall clock (stable on Boox); fall back to MediaPlayer if wall
    -- has not locked yet.  Then re-anchor so pause/resume stay on the SMIL
    -- timeline instead of drifting back to the original play-from-here mark.
    local pos = self:_wallPositionMs()
    if not self._audio_started then
        local mp = self:_queryMpPositionMs()
        if mp and mp > (pos or 0) then pos = mp end
    end
    pos = math.max(0, math.floor(tonumber(pos) or 0))
    if not self._paused then
        local android = self._android
        android.jni:context(android.app.activity.vm, function(jni)
            jni.env[0].CallVoidMethod(jni.env, self._mp_ref, self._method.pause)
            checkException(jni.env)
        end)
        self._paused = true
    end
    -- Clean re-anchor at the pause point (clears pause_accum drift).
    self:_reanchorWallToMs(pos)
    self._paused = true
    self._pause_wall_start = UIManager:getTime()
    self._audio_started = true
    self._ever_confirmed_playing = true
    self._last_mp_pos_ms = pos
    self._eos_reached_at = nil
    logger.warn("AndroidPlayer: paused at pos_ms=", pos)
    return pos
end

function AndroidPlayer:resume()
    if not self._mp_ref then return false end
    local resume_ms = self._last_mp_pos_ms or self:_wallPositionMs() or 0
    resume_ms = math.max(0, math.floor(tonumber(resume_ms) or 0))

    -- Explicit seek + start so MediaPlayer and the SMIL wall clock agree.
    -- Some Boox/HAL paths resume from an earlier buffered position after pause.
    local android = self._android
    android.jni:context(android.app.activity.vm, function(jni)
        local env = jni.env
        if resume_ms > 50 and self._method.seekTo then
            local args = ffi.new("jvalue[1]")
            args[0].i = resume_ms
            env[0].CallVoidMethodA(env, self._mp_ref, self._method.seekTo, args)
            checkException(env)
        end
        env[0].CallVoidMethod(env, self._mp_ref, self._method.start)
        checkException(env)
    end)

    self:_reanchorWallToMs(resume_ms)
    self._paused = false
    self._playing = true
    self._audio_started = true
    self._ever_confirmed_playing = true
    self._eos_reached_at = nil
    logger.warn("AndroidPlayer: resumed at pos_ms=", resume_ms)
    return true
end

function AndroidPlayer:stop()
    self:_releasePlayer()
    self._wall_start = nil
    self._ever_confirmed_playing = false
    self._audio_started = false
    self._mp_baseline_ms = nil
    self._mp_stuck_reads = 0
    self._eos_reached_at = nil
end

function AndroidPlayer:seekToMs(msec)
    if not self._mp_ref then return end
    msec = math.floor(tonumber(msec) or 0)
    local android = self._android
    android.jni:context(android.app.activity.vm, function(jni)
        local env = jni.env
        local args = ffi.new("jvalue[1]")
        args[0].i = msec
        env[0].CallVoidMethodA(env, self._mp_ref, self._method.seekTo, args)
        checkException(env)
    end)
    self:_reanchorWallToMs(msec)
    self._audio_started = true
    self._ever_confirmed_playing = true
    self._mp_baseline_ms = nil
    self._mp_stuck_reads = 0
    self._eos_reached_at = nil
end

--- Position for sync and completion: monotonic wall-clock after a one-shot
--- lock at audible start.  Never poll MediaPlayer continuously for sync —
--- on Boox getCurrentPosition() jitters and made highlights thrash.
function AndroidPlayer:getPositionMs()
    if self._paused then
        return self:_wallPositionMs()
    end

    if not self._audio_started then
        local mp = self:_queryMpPositionMs()
        if not self:_tryLockWallClock(mp) then
            return self._start_seek_ms or 0
        end
    end

    return self:_wallPositionMs()
end

function AndroidPlayer:getDurationMs()
    if self._duration_ms and self._duration_ms > 0 then
        return self._duration_ms
    end
    if not self._mp_ref or not self._method.getDuration then return 0 end
    local android = self._android
    local dur = android.jni:context(android.app.activity.vm, function(jni)
        local d = jni.env[0].CallIntMethod(jni.env,
            self._mp_ref, self._method.getDuration)
        if checkException(jni.env) then return 0 end
        return tonumber(d) or 0
    end) or 0
    self._duration_ms = dur
    return dur
end

function AndroidPlayer:isPlaying()
    if not self._mp_ref then return false end
    if self._paused then return false end
    -- Trust our own state: MediaPlayer.isPlaying() is flaky across JNI and
    -- would false-complete the sync loop while audio still plays.
    return self._playing and true or false
end

-- After wall-clock hits MediaPlayer duration, wait this long before telling
-- the playlist to advance.  The next-track path stop()s MediaPlayer immediately;
-- on Boox (and BT/AirPods) the HAL still holds the last ~word or two.  Completing
-- 400 ms *early* used to clip those words; draining 400 ms *after* duration
-- lets them play, at the cost of a short gap between Storyteller parts.
local EOS_DRAIN_MS = 400

function AndroidPlayer:isPlaybackDone()
    if not self._mp_ref then return true end
    if self._paused then return false end
    if not self._playing then return true end

    -- Duration-only completion.  Do NOT ask MediaPlayer.isPlaying() — on Boox
    -- it flaps false mid-play / on pause and was causing false EOS → restart
    -- from the original "play from here" seek offset.
    local pos = self:getPositionMs()
    local dur = self:getDurationMs()
    if not (dur and dur > 0 and pos >= dur) then
        self._eos_reached_at = nil
        return false
    end

    if not self._eos_reached_at then
        self._eos_reached_at = UIManager:getTime()
        logger.warn("AndroidPlayer: duration reached, draining", EOS_DRAIN_MS,
            "ms before next track  pos_ms=", pos, "dur_ms=", dur)
        return false
    end
    local waited = time.to_ms(UIManager:getTime() - self._eos_reached_at) or 0
    if waited < EOS_DRAIN_MS then
        return false
    end
    self._playing = false
    logger.warn("AndroidPlayer: EOS after drain  waited_ms=", waited)
    return true
end

function AndroidPlayer:shutdown()
    self:stop()
    if self._attrs_ref and self._android then
        self._android.jni:context(self._android.app.activity.vm, function(jni)
            jni.env[0].DeleteGlobalRef(jni.env, self._attrs_ref)
        end)
        self._attrs_ref = nil
    end
    if self._mp_class and self._android then
        self._android.jni:context(self._android.app.activity.vm, function(jni)
            jni.env[0].DeleteGlobalRef(jni.env, self._mp_class)
        end)
        self._mp_class = nil
    end
    if self._pp_class and self._android then
        self._android.jni:context(self._android.app.activity.vm, function(jni)
            jni.env[0].DeleteGlobalRef(jni.env, self._pp_class)
        end)
        self._pp_class = nil
    end
    self._initialized = false
end

return AndroidPlayer
