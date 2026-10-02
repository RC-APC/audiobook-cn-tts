--[[--
Audiobookshelf Progress Sync Controller
Manages bi-directional progress synchronization between local playback and ABS.
Writes to a local sync journal immediately; flushes to ABS when connected.

@module abssync
--]]

local logger = require("logger")
local _ = require("audiobook_gettext")

local ABSSync = {}

function ABSSync:new(o)
    o = o or {}
    setmetatable(o, self)
    self.__index = self

    o.plugin = o.plugin
    o.plugin_dir = o.plugin_dir or "."
    o.journal_path = o.plugin_dir .. "/abs_sync_journal.json"

    -- In-memory journal
    o.journal = {}
    o:_loadJournal()

    return o
end

-- ---------------------------------------------------------------------------
-- Internal: journal persistence
-- ---------------------------------------------------------------------------

function ABSSync:_loadJournal()
    local f = io.open(self.journal_path, "r")
    if f then
        local content = f:read("*a")
        f:close()
        if content and content ~= "" then
            local JSON = require("json")
            local ok, data = pcall(JSON.decode, content)
            if ok and type(data) == "table" then
                self.journal = data
                logger.dbg("ABSSync: loaded journal with", #self.journal, "entries")
                return
            end
        end
    end
    self.journal = {}
end

function ABSSync:_saveJournal()
    local JSON = require("json")
    local ok, json_str = pcall(JSON.encode, self.journal)
    if not ok then
        logger.err("ABSSync: failed to encode journal:", json_str)
        return false
    end

    local f = io.open(self.journal_path, "w")
    if f then
        f:write(json_str)
        f:close()
        return true
    else
        logger.err("ABSSync: failed to write journal to", self.journal_path)
        return false
    end
end

-- ---------------------------------------------------------------------------
-- Progress recording
-- ---------------------------------------------------------------------------

--[[--
Record a playback progress update locally.
Called by main.lua on pause, stop, and periodic ticks.
@param item_id string
@param local_file_path string
@param position number  Current position in seconds
@param duration number  Total duration in seconds
@param is_finished boolean
--]]
function ABSSync:recordProgress(item_id, local_file_path, position, duration, is_finished)
    if not item_id then
        return
    end

    -- Debounce: don't record if position hasn't changed meaningfully
    local last_entry = self:_findLastEntry(item_id)
    if last_entry and math.abs(last_entry.position - position) < 5 then
        -- Position changed by less than 5 seconds; skip
        return
    end

    local entry = {
        item_id = item_id,
        local_file_path = local_file_path,
        position = position or 0,
        duration = duration or 0,
        is_finished = is_finished or false,
        local_timestamp = os.time(),
        synced = false,
    }

    table.insert(self.journal, entry)

    -- Prune journal to last 100 entries
    if #self.journal > 100 then
        local new_journal = {}
        for i = #self.journal - 99, #self.journal do
            table.insert(new_journal, self.journal[i])
        end
        self.journal = new_journal
    end

    self:_saveJournal()
    logger.dbg("ABSSync: recorded progress for", item_id, "@", position, "s")
end

function ABSSync:_findLastEntry(item_id)
    for i = #self.journal, 1, -1 do
        if self.journal[i].item_id == item_id then
            return self.journal[i]
        end
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- Flush to server
-- ---------------------------------------------------------------------------

--[[--
Flush unsynced journal entries to ABS.
@param client ABSClient instance
@return boolean, string|nil  success, error_message
--]]
function ABSSync:flush(client)
    if not client then
        return false, _("No ABS client available.")
    end

    -- Collect unsynced entries, grouped by item_id (keep only latest per item)
    local latest_by_item = {}
    for _, entry in ipairs(self.journal) do
        if not entry.synced then
            local existing = latest_by_item[entry.item_id]
            if not existing or entry.local_timestamp > existing.local_timestamp then
                latest_by_item[entry.item_id] = entry
            end
        end
    end

    local updates = {}
    for _, entry in pairs(latest_by_item) do
        table.insert(updates, {
            libraryItemId = entry.item_id,
            currentTime = entry.position,
            duration = entry.duration,
            isFinished = entry.is_finished,
        })
    end

    if #updates == 0 then
        return true, nil
    end

    logger.warn("ABSSync: flushing", #updates, "progress update(s) to ABS")

    local ok, err
    if #updates == 1 then
        ok, err = client:updateProgress(
            updates[1].libraryItemId,
            updates[1].currentTime,
            updates[1].duration,
            updates[1].isFinished
        )
    else
        ok, err = client:batchSyncProgress(updates)
    end

    if ok then
        -- Mark flushed entries as synced
        local flush_time = os.time()
        for _, entry in ipairs(self.journal) do
            if not entry.synced and latest_by_item[entry.item_id] then
                entry.synced = true
                entry.synced_at = flush_time
            end
        end
        self:_saveJournal()
        logger.warn("ABSSync: flush successful")
        return true, nil
    else
        logger.warn("ABSSync: flush failed:", err)
        return false, err
    end
end

-- ---------------------------------------------------------------------------
-- Bi-directional sync
-- ---------------------------------------------------------------------------

--[[--
Sync all locally cached ABS items.
For each item:
  1. Fetch remote progress from ABS
  2. Compare timestamps
  3. If remote is newer: update local position
  4. If local is newer: push to ABS
@param client ABSClient instance
@param cache ABSCache instance
@return boolean, string|nil  success, error_message
--]]
function ABSSync:syncAllLocalItems(client, cache)
    if not client or not cache then
        return false, _("Client or cache not available.")
    end

    local items = cache:listCachedItems()
    if #items == 0 then
        return true, nil
    end

    logger.warn("ABSSync: syncing", #items, "local items")
    local had_error = false

    for _, item in ipairs(items) do
        local ok, remote_progress = pcall(function()
            return client:getProgress(item.id)
        end)

        if ok and remote_progress then
            local remote_time = remote_progress.lastUpdate or 0
            local local_entry = self:_findLastEntry(item.id)
            local local_time = local_entry and local_entry.local_timestamp or 0

            if remote_time > local_time then
                -- Remote is newer: update local position
                logger.warn("ABSSync: remote progress newer for", item.id,
                    "updating local position to", remote_progress.currentTime)
                self:_updateLocalPosition(item, remote_progress.currentTime)
            elseif local_time > remote_time and local_entry and not local_entry.synced then
                -- Local is newer: push to ABS (will be handled by flush)
                logger.dbg("ABSSync: local progress newer for", item.id)
            end
        elseif not ok then
            had_error = true
            logger.warn("ABSSync: failed to get remote progress for", item.id, ":", remote_progress)
        end
    end

    -- Flush any pending local updates
    local flush_ok, flush_err = self:flush(client)
    if not flush_ok then
        had_error = true
    end

    if had_error then
        return false, _("Some items could not be synced.")
    end
    return true, nil
end

--[[--
Update the local saved position for an ABS item.
Writes to the plugin's audio_positions setting so the normal resume flow works.
@param item table  Cache entry
@param position number
--]]
function ABSSync:_updateLocalPosition(item, position)
    if not item or not item.audio_files or #item.audio_files == 0 then
        return
    end

    local audio_path = item.audio_files[1]
    if self.plugin and self.plugin._savePosition then
        self.plugin:_savePosition(audio_path, position)
        logger.dbg("ABSSync: updated local position for", audio_path, "to", position)
    end
end

-- ---------------------------------------------------------------------------
-- Position queries
-- ---------------------------------------------------------------------------

--[[--
Get the best-known local position for an ABS item.
Checks sync journal first, then falls back to the plugin's saved positions.
@param item_id string
@return number|nil
--]]
function ABSSync:getLocalPosition(item_id)
    local entry = self:_findLastEntry(item_id)
    if entry then
        return entry.position
    end
    return nil
end

--[[--
Get the best-known remote position for an ABS item.
@param client ABSClient instance
@param item_id string
@return number|nil, string|nil  position, error_message
--]]
function ABSSync:getRemotePosition(client, item_id)
    if not client then
        return nil, _("No client available.")
    end

    local ok, progress = pcall(function()
        return client:getProgress(item_id)
    end)

    if ok and progress then
        return progress.currentTime, nil
    end

    return nil, progress  -- progress is error message on failure
end

--[[--
Get the best position (local or remote, whichever is newer).
@param client ABSClient instance
@param item_id string
@return number|nil
--]]
function ABSSync:getBestPosition(client, item_id)
    local local_pos = self:getLocalPosition(item_id)
    local remote_pos, err = self:getRemotePosition(client, item_id)

    if remote_pos and local_pos then
        -- Use whichever has a more recent journal entry
        local local_entry = self:_findLastEntry(item_id)
        if local_entry and local_entry.synced then
            -- Local was synced; remote might be newer from another device
            return remote_pos
        else
            -- Local has unsynced changes; prefer local
            return local_pos
        end
    elseif remote_pos then
        return remote_pos
    elseif local_pos then
        return local_pos
    end

    return nil
end

-- ---------------------------------------------------------------------------
-- Cleanup
-- ---------------------------------------------------------------------------

--[[--
Remove entries for items no longer in cache.
@param cache ABSCache instance
--]]
function ABSSync:pruneOrphanedEntries(cache)
    if not cache then
        return
    end

    local new_journal = {}
    local removed = 0
    for _, entry in ipairs(self.journal) do
        if cache:getItem(entry.item_id) then
            table.insert(new_journal, entry)
        else
            removed = removed + 1
        end
    end

    if removed > 0 then
        self.journal = new_journal
        self:_saveJournal()
        logger.warn("ABSSync: pruned", removed, "orphaned journal entries")
    end
end

return ABSSync
