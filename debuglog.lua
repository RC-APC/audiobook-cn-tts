--[[--
Ring-buffer + on-disk debug log for audiobook.koplugin.

Included in bug reports so Android/Boox issues can be diagnosed without
adb logcat.  No book text is logged — only short diagnostic strings.

@module debuglog
--]]

local DebugLog = {}

local MAX_LINES = 250
local MAX_FILE_BYTES = 180 * 1024
local _lines = {}
local _path = nil
local _initialized = false

local function ensureDir(path)
    -- Best-effort mkdir for the parent of path.
    local dir = path:match("^(.*)/[^/]+$")
    if not dir or dir == "" then return end
    os.execute('mkdir -p "' .. dir:gsub('"', '\\"') .. '" 2>/dev/null')
end

--- Initialize log path (call once from plugin init).
-- @param plugin_dir string
function DebugLog.init(plugin_dir)
    if not plugin_dir or plugin_dir == "" then return end
    plugin_dir = plugin_dir:gsub("//+", "/"):gsub("/+$", "")
    _path = plugin_dir .. "/debug.log"
    ensureDir(_path)
    -- Truncate if the file grew too large.
    local f = io.open(_path, "r")
    if f then
        local size = f:seek("end")
        f:close()
        if size and size > MAX_FILE_BYTES then
            os.remove(_path)
        end
    end
    _initialized = true
    DebugLog.log("DebugLog: ready path=", _path)
end

--- Append a debug line (also kept in memory for bug reports).
function DebugLog.log(...)
    local n = select("#", ...)
    local parts = {}
    for i = 1, n do
        parts[i] = tostring(select(i, ...))
    end
    local line = os.date("!%Y-%m-%dT%H:%M:%SZ ") .. table.concat(parts, " ")
    _lines[#_lines + 1] = line
    while #_lines > MAX_LINES do
        table.remove(_lines, 1)
    end
    if _path then
        local f = io.open(_path, "a")
        if f then
            f:write(line, "\n")
            f:close()
        end
    end
end

--- Return the in-memory tail (and last lines from disk if memory is empty).
-- @param max_lines number|nil
-- @return string
function DebugLog.tail(max_lines)
    max_lines = max_lines or 120
    if #_lines > 0 then
        local start = math.max(1, #_lines - max_lines + 1)
        return table.concat(_lines, "\n", start, #_lines)
    end
    if not _path then return "(no debug log yet)" end
    local f = io.open(_path, "r")
    if not f then return "(debug.log not found)" end
    local content = f:read("*a") or ""
    f:close()
    if content == "" then return "(debug.log empty)" end
    local collected = {}
    for line in content:gmatch("[^\n]+") do
        collected[#collected + 1] = line
    end
    local start = math.max(1, #collected - max_lines + 1)
    return table.concat(collected, "\n", start, #collected)
end

function DebugLog.path()
    return _path
end

function DebugLog.isReady()
    return _initialized and _path ~= nil
end

return DebugLog
