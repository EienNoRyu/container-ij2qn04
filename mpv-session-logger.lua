local utils = require("mp.utils")

local log_path = mp.command_native({"expand-path", "~~/session_activity.log"})
local state_path = mp.command_native({"expand-path", "~~/session_state.json"})
local restore_seek_delay_seconds = 0.2
local state_flush_interval_seconds = 2

local state = {
    playlist = {},
    current_index = 1,
    updated_at = os.time(),
}

local previous_playlist_filenames = {}
local restore_prompt_active = false
local restore_prompt_timer = nil
local restore_prompt_seen = false
local pending_state_update = false

local function append_log(event_name, payload)
    local file = io.open(log_path, "a")
    if not file then
        return
    end
    local event = {
        ts = os.date("!%Y-%m-%dT%H:%M:%SZ"),
        event = event_name,
        payload = payload or {},
    }
    file:write((utils.format_json(event) or "{}") .. "\n")
    file:close()
end

local function write_state()
    state.updated_at = os.time()
    local file = io.open(state_path, "w")
    if not file then
        return
    end
    file:write(utils.format_json(state) or "{}")
    file:close()
end

local function read_state_file()
    local file = io.open(state_path, "r")
    if not file then
        return nil
    end
    local content = file:read("*a")
    file:close()
    if not content or content == "" then
        return nil
    end
    return utils.parse_json(content)
end

local function snapshot_playlist()
    local playlist = mp.get_property_native("playlist") or {}
    local playlist_pos = (mp.get_property_number("playlist-pos", 0) or 0) + 1
    local entries = {}

    for i, item in ipairs(playlist) do
        local is_current = i == playlist_pos
        local time_pos = 0
        local duration = 0

        if is_current then
            time_pos = mp.get_property_number("time-pos", 0) or 0
            duration = mp.get_property_number("duration", 0) or 0
        end

        entries[#entries + 1] = {
            filename = item.filename,
            title = item.title,
            is_current = is_current,
            time_pos = time_pos,
            duration = duration,
        }
    end

    state.playlist = entries
    state.current_index = playlist_pos
end

local function filenames_map(playlist)
    local map = {}
    for _, item in ipairs(playlist or {}) do
        if item.filename then
            map[item.filename] = (map[item.filename] or 0) + 1
        end
    end
    return map
end

local function detect_playlist_changes(new_playlist)
    local current = filenames_map(new_playlist)
    local previous = previous_playlist_filenames

    for filename, count in pairs(current) do
        local old_count = previous[filename] or 0
        if count > old_count then
            append_log("playlist_item_added", {
                filename = filename,
                count = count - old_count,
            })
        end
    end

    for filename, count in pairs(previous) do
        local new_count = current[filename] or 0
        if count > new_count then
            append_log("playlist_item_removed", {
                filename = filename,
                count = count - new_count,
            })
        end
    end

    previous_playlist_filenames = current
end

local function update_and_save()
    snapshot_playlist()
    write_state()
end

local function queue_state_update()
    pending_state_update = true
end

local function clear_restore_prompt()
    if restore_prompt_timer then
        restore_prompt_timer:kill()
        restore_prompt_timer = nil
    end
    if restore_prompt_active then
        mp.remove_key_binding("restore_session_click")
        mp.remove_key_binding("dismiss_restore_prompt")
        restore_prompt_active = false
    end
end

local function restore_session()
    local saved = read_state_file()
    clear_restore_prompt()
    if not saved or not saved.playlist or #saved.playlist == 0 then
        mp.osd_message("No saved session found.")
        return
    end

    mp.commandv("playlist-clear")
    for i, item in ipairs(saved.playlist) do
        if item.filename and item.filename ~= "" then
            if i == 1 then
                mp.commandv("loadfile", item.filename, "replace")
            else
                mp.commandv("loadfile", item.filename, "append-play")
            end
        end
    end

    local restore_index = saved.current_index or 1
    local current_item = saved.playlist[restore_index]
    local restore_time = current_item and current_item.time_pos or 0
    mp.add_timeout(restore_seek_delay_seconds, function()
        mp.set_property_number("playlist-pos", math.max(0, restore_index - 1))
        if restore_time and restore_time > 0 then
            mp.commandv("seek", tostring(restore_time), "absolute", "exact")
        end
    end)

    append_log("session_restored", {
        item_count = #saved.playlist,
        restored_index = restore_index,
        restored_time = restore_time or 0,
    })
    mp.osd_message("Last session restored.")
end

local function maybe_offer_restore()
    if restore_prompt_active or restore_prompt_seen then
        return
    end
    local info = utils.file_info(state_path)
    if not info then
        return
    end

    restore_prompt_seen = true
    restore_prompt_active = true
    mp.add_forced_key_binding("MBTN_LEFT", "restore_session_click", function()
        restore_session()
    end)
    mp.add_forced_key_binding("ESC", "dismiss_restore_prompt", function()
        clear_restore_prompt()
        mp.osd_message("Restore dismissed.")
    end)
    mp.osd_message("Restore last MPV session?\nLeft click: Restore | ESC: Dismiss", 20)
    restore_prompt_timer = mp.add_timeout(20, function()
        clear_restore_prompt()
    end)
end

mp.register_event("start-file", function()
    local path = mp.get_property("path")
    append_log("file_opened", {path = path})
    update_and_save()
end)

mp.observe_property("playlist", "native", function(_, playlist)
    detect_playlist_changes(playlist or {})
    update_and_save()
end)

mp.observe_property("time-pos", "number", function(_, value)
    if value == nil then
        return
    end
    queue_state_update()
end)

mp.observe_property("duration", "number", function(_, value)
    if value == nil then
        return
    end
    queue_state_update()
end)

mp.add_periodic_timer(state_flush_interval_seconds, function()
    if pending_state_update then
        pending_state_update = false
        update_and_save()
    end
end)

mp.register_event("idle", function()
    maybe_offer_restore()
end)

mp.register_event("shutdown", function()
    append_log("mpv_shutdown", {})
    update_and_save()
end)
