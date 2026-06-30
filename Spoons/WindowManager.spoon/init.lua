--- === WindowManager ===
---
--- Advanced window manager with tiling and fullscreen management
---
--- Download: [https://github.com/AndrewDryga/spoons/raw/main/WindowManager.spoon.zip](https://github.com/AndrewDryga/spoons/raw/main/WindowManager.spoon.zip)

local obj = {}
obj.__index = obj

-- Metadata
obj.name = "WindowManager"
obj.version = "1.0.0"
obj.author = "Andrew Dryga"
obj.homepage = "https://github.com/AndrewDryga/spoons"
obj.license = "MIT - https://opensource.org/licenses/MIT"

-- Window manager for Hammerspoon: tiling + deterministic fullscreen with minimal hops.
-- Refactored version with improved robustness, timeout handling, and user experience
---@diagnostic disable-next-line: undefined-global, lowercase-global
hs = hs or {}

local M = {}

--------------------------------------------------------------------------------
-- Constants
--------------------------------------------------------------------------------
local SPACE_TYPES = {
    USER = "user",
    FULLSCREEN = "fullscreen"
}

local NOTIFICATION_TYPES = {
    INFO = "informational",
    WARNING = "warning",
    ERROR = "error"
}

--------------------------------------------------------------------------------
-- Timing Configuration (grouped by feature)
--------------------------------------------------------------------------------
local T = {
    -- Space navigation
    SPACE = {
        HOP_TIMEOUT = 2.0,
        HOP_POLL_INTERVAL = 0.02,
        HOP_SETTLE_DELAY = 0.2,
        HOP_MAX_RETRIES = 2,
    },

    -- Fullscreen operations
    FULLSCREEN = {
        CREATE_TIMEOUT = 2.0,
        CREATE_POLL_INTERVAL = 0.1,
        SET_DELAY = 0.1,
        EXIT_TIMEOUT = 1.2,
        EXIT_POLL_INTERVAL = 0.12,
        EXIT_KEY_DELAY = 0.18,
        POST_EXIT_PRECOLLECT_DELAY = 0.05,
        POST_EXIT_CALLBACK_DELAY = 0.05,
    },

    -- App operations
    APP = {
        READY_POLL_INTERVAL = 0.2,
        READY_TIMEOUT = 5.0,
        LAUNCH_THROTTLE_SEC = 2.0,
        WINDOW_POLL_TIMEOUT = 3.0,
    },

    -- UI operations
    UI = {
        APPLESCRIPT_DELAY = 0.12,
        SECOND_TILING_PASS_DELAY = 0.18,
        SCREEN_DEBOUNCE_DELAY = 1.0,
        NOTIFICATION_DURATION = 3.0,
    },

    -- Performance tuning
    PERF = {
        CACHE_TTL_SECONDS = 300,         -- 5 minutes
        THROTTLE_CLEANUP_INTERVAL = 600, -- 10 minutes
    }
}

--------------------------------------------------------------------------------
-- Module State
--------------------------------------------------------------------------------
local state = {
    config = nil,
    screen_watcher = nil,
    space_watcher = nil,
    app_watcher = nil,
    active_hotkeys = {},
    current_screen_name = nil,
    current_screen = nil,
    debounce_timer = nil,
    launch_throttle = {},
    model = {
        spaces = {}, -- spaceID -> { type, occupantBid, timestamp }
    },
    is_discovering_spaces = false,
    is_applying = false,
    active_operations = {},     -- track active async operations for cleanup
    operation_id = 0,           -- incrementing ID for operations
    current_operation_id = 0,   -- token for the in-flight layout op (cancellation)
    last_notification = nil,    -- track last notification for updates
}

--------------------------------------------------------------------------------
-- Logging and User Feedback
--------------------------------------------------------------------------------
local Logger = {
    level = nil, -- set based on config.debug
}

function Logger:init(debug_enabled)
    self.level = debug_enabled and 1 or 2 -- 1=DEBUG, 2=INFO, 3=WARN, 4=ERROR
end

function Logger:log(level, fmt, ...)
    if not self.level or level < self.level then return end

    local prefixes = { "[DEBUG]", "[INFO]", "[WARN]", "[ERROR]" }
    local prefix = prefixes[level] or "[?]"
    print(string.format("%s[wm] " .. fmt, prefix, ...))
end

function Logger:debug(fmt, ...) self:log(1, fmt, ...) end

function Logger:info(fmt, ...) self:log(2, fmt, ...) end

function Logger:warn(fmt, ...) self:log(3, fmt, ...) end

function Logger:error(fmt, ...) self:log(4, fmt, ...) end

-- User notifications for important events
local Notifier = {}

function Notifier:show(title, text, type)
    -- Check if notifications are enabled in config
    if not (state.config and state.config.notifications) then
        return nil
    end

    type = type or NOTIFICATION_TYPES.INFO

    -- Cancel previous notification if it exists
    if state.last_notification then
        pcall(function() state.last_notification:withdraw() end)
    end

    local notification = hs.notify.new(function() end, {
        title = "[Window Manager] " .. title,
        informativeText = text,
        soundName = (type == NOTIFICATION_TYPES.ERROR) and hs.notify.defaultNotificationSound or nil,
        withdrawAfter = T.UI.NOTIFICATION_DURATION,
    })

    if notification then
        notification:send()
        state.last_notification = notification
    end
    return notification
end

function Notifier:showProgress(operation, current, total)
    if not (state.config and state.config.notifications) then
        return nil
    end
    local percent = math.floor((current / total) * 100)
    local text = string.format("%s: %d/%d (%d%%)", operation, current, total, percent)
    self:show("Layout Progress", text, NOTIFICATION_TYPES.INFO)
end

function Notifier:showError(operation, error_msg)
    if not (state.config and state.config.notifications) then
        return nil
    end
    self:show(operation .. " Failed", error_msg, NOTIFICATION_TYPES.ERROR)
end

--------------------------------------------------------------------------------
-- Utilities
--------------------------------------------------------------------------------

-- Convert value to array
local function to_array(val)
    if type(val) == "table" then return val end
    if val == nil then return {} end
    return { val }
end

-- Safe app retrieval
local function get_app(bundle_id)
    if not bundle_id then return nil end
    local ok, app = pcall(hs.application.get, bundle_id)
    return ok and app or nil
end

-- Generate operation ID for tracking
local function generate_operation_id()
    state.operation_id = state.operation_id + 1
    return state.operation_id
end

-- Track active operation
local function track_operation(op_id, cleanup_fn)
    state.active_operations[op_id] = cleanup_fn
end

-- Clean up operation
local function cleanup_operation(op_id)
    local cleanup = state.active_operations[op_id]
    state.active_operations[op_id] = nil -- Remove first to prevent recursion
    if cleanup and type(cleanup) == "function" then
        local ok, err = pcall(cleanup)
        if not ok then
            Logger:warn("Cleanup failed for operation %d: %s", op_id, err)
        end
    end
end

-- Clean up all operations (for teardown)
local function cleanup_all_operations()
    for op_id, _ in pairs(state.active_operations) do
        cleanup_operation(op_id)
    end
end

--------------------------------------------------------------------------------
-- Enhanced Polling with Retries and Progress
--------------------------------------------------------------------------------

-- Options for pollUntil:
-- {
--   interval: poll interval in seconds
--   timeout: max time in seconds
--   retries: number of retries on timeout
--   backoff: backoff multiplier for retries
--   progress_fn: optional function(elapsed, timeout) for progress updates
-- }
local function pollUntil(label, checkFn, opts, on_done)
    opts = opts or {}
    local interval = opts.interval or 0.1
    local timeout = opts.timeout or 2.0
    local retries = opts.retries or 0
    local backoff = opts.backoff or 1.5
    local progress_fn = opts.progress_fn

    local op_id = generate_operation_id()
    local current_retry = 0
    local current_timeout = timeout

    local function attempt()
        local start_time = hs.timer.secondsSinceEpoch()
        local deadline = start_time + current_timeout
        local poller

        local function cleanup()
            if poller then
                poller:stop()
                poller = nil
            end
            -- Don't call cleanup_operation here as it would cause recursion
            state.active_operations[op_id] = nil
        end

        local function on_success(result)
            Logger:debug("[pollUntil:%s] success after %d retries", label, current_retry)
            cleanup()
            if on_done then on_done(true, result) end
        end

        local function on_timeout()
            cleanup()
            state.active_operations[op_id] = nil -- Ensure cleanup

            if current_retry < retries then
                current_retry = current_retry + 1
                current_timeout = current_timeout * backoff
                Logger:info("[pollUntil:%s] timeout, retry %d/%d with %.1fs timeout",
                    label, current_retry, retries, current_timeout)
                hs.timer.doAfter(0.1 * current_retry, attempt) -- increasing delay between retries
            else
                Logger:warn("[pollUntil:%s] failed after %d retries", label, current_retry)
                if on_done then on_done(false, nil) end
            end
        end

        poller = hs.timer.new(interval, function()
            local elapsed = hs.timer.secondsSinceEpoch() - start_time

            -- Call progress function if provided
            if progress_fn then
                progress_fn(elapsed, current_timeout)
            end

            -- Check the condition
            local ok, res = pcall(checkFn)
            if ok and res then
                return on_success(res)
            end

            -- Check for timeout
            if hs.timer.secondsSinceEpoch() > deadline then
                return on_timeout()
            end
        end)

        track_operation(op_id, cleanup)
        poller:start()
    end

    attempt()
end

--------------------------------------------------------------------------------
-- App Launch Management
--------------------------------------------------------------------------------

local function quiet_launch(bundle_id)
    if not bundle_id then return false end

    local now = hs.timer.secondsSinceEpoch()
    local last_launch = state.launch_throttle[bundle_id] or 0

    if (now - last_launch) < T.APP.LAUNCH_THROTTLE_SEC then
        Logger:debug("Throttled launch for %s", bundle_id)
        return false
    end

    state.launch_throttle[bundle_id] = now

    -- Periodic cleanup of old entries
    for bid, timestamp in pairs(state.launch_throttle) do
        if (now - timestamp) > T.PERF.THROTTLE_CLEANUP_INTERVAL then
            state.launch_throttle[bid] = nil
        end
    end

    Logger:info("Quietly launching %s", bundle_id)
    local ok, task = pcall(hs.task.new, "/usr/bin/open", nil, { "-gj", "-b", bundle_id })
    if ok and task then
        task:start()
        return true
    else
        Logger:error("Failed to launch %s", bundle_id)
        return false
    end
end

local function ensure_apps_running(bundle_ids, with_progress)
    local apps_to_wait_for = {}
    local total = #bundle_ids
    local launched = 0

    for i, bid in ipairs(bundle_ids) do
        local app = get_app(bid)
        if not (app and app:isRunning()) then
            if quiet_launch(bid) then
                apps_to_wait_for[bid] = true
                launched = launched + 1
            end
        end

        if with_progress and total > 1 and state.config and state.config.notifications then
            Notifier:showProgress("Launching apps", i, total)
        end
    end

    if launched > 0 then
        Logger:info("Launched %d/%d apps", launched, total)
    end

    return apps_to_wait_for
end

--------------------------------------------------------------------------------
-- Window Fullscreen Detection
--------------------------------------------------------------------------------

local function is_effectively_fullscreen(win)
    if not win then return false end

    -- Check direct flag first
    if win:isFullScreen() then
        return true
    end

    -- Check if window is in a fullscreen space
    local ok, spaces = pcall(hs.spaces.windowSpaces, win)
    if ok and spaces and #spaces == 1 then
        local space_type = hs.spaces.spaceType(spaces[1])
        if space_type == SPACE_TYPES.FULLSCREEN then
            return true
        end
    end

    return false
end

--------------------------------------------------------------------------------
-- Window Exit Fullscreen (Robust Multi-Method Approach)
--------------------------------------------------------------------------------

local function exit_fullscreen_for_app(app, callback)
    if not app then
        if callback then callback(nil) end
        return
    end

    -- Verify app still exists
    if not pcall(function() return app:name() end) then
        Logger:warn("App no longer exists during exit_fullscreen")
        if callback then callback(nil) end
        return
    end

    local app_name = app:name() or "<unknown>"
    local bundle_id = app:bundleID() or "<unknown>"
    Logger:info("Exiting fullscreen for '%s' (%s)", app_name, bundle_id)

    -- Track how many windows need to exit fullscreen
    local fs_windows = {}
    for _, win in ipairs(app:allWindows() or {}) do
        if is_effectively_fullscreen(win) then
            table.insert(fs_windows, win:id())
        end
    end

    if #fs_windows == 0 then
        Logger:debug("No fullscreen windows found for '%s'", app_name)
        if callback then callback(app) end
        return
    end

    Logger:debug("Found %d fullscreen windows for '%s'", #fs_windows, app_name)

    -- Method 1: native, non-blocking "View > Exit Full Screen" menu click.
    -- Replaces a synchronous System Events AppleScript (activate + delay + menu
    -- walk) that froze Hammerspoon's main loop ~0.5s per app. The app is already
    -- frontmost on its own fullscreen Space here, so no activate is needed; the
    -- direct/keyboard methods + the poll below remain as fallbacks.
    local menu_ok = pcall(function() app:selectMenuItem({ "View", "Exit Full Screen" }) end)
    Logger:debug("selectMenuItem exit-fullscreen for '%s' (ok=%s)", app_name, tostring(menu_ok))

    -- Method 2: Direct window flag
    for _, win in ipairs(app:allWindows() or {}) do
        if is_effectively_fullscreen(win) then
            local ok, err = pcall(function() win:setFullScreen(false) end)
            if not ok then
                Logger:debug("setFullScreen(false) failed for '%s': %s", app_name, err)
            end
        end
    end

    -- Method 3: Keyboard shortcut fallback (after delay)
    hs.timer.doAfter(T.FULLSCREEN.EXIT_KEY_DELAY, function()
        -- Check if app still exists
        if not pcall(function() return app:name() end) then
            Logger:warn("App disappeared during exit_fullscreen")
            if callback then callback(nil) end
            return
        end

        -- Check if still fullscreen
        local still_fs = false
        for _, win in ipairs(app:allWindows() or {}) do
            if is_effectively_fullscreen(win) then
                still_fs = true
                break
            end
        end

        if still_fs then
            Logger:debug("Trying keyboard fallback for '%s'", app_name)
            pcall(function()
                hs.eventtap.keyStroke({ "cmd", "ctrl" }, "f", 0)
            end)
        end
    end)

    -- Poll for completion
    pollUntil("exit_fs_" .. bundle_id, function()
        -- Verify app still exists
        if not pcall(function() return app:name() end) then
            return true -- App gone, consider it done
        end

        for _, win in ipairs(app:allWindows() or {}) do
            if is_effectively_fullscreen(win) then
                return false
            end
        end
        return true
    end, {
        interval = T.FULLSCREEN.EXIT_POLL_INTERVAL,
        timeout = T.FULLSCREEN.EXIT_TIMEOUT,
        retries = 1,
    }, function(success, _)
        if success then
            Logger:info("Successfully exited fullscreen for '%s'", app_name)
        else
            Logger:warn("Timeout exiting fullscreen for '%s'", app_name)
        end

        -- Small delay for space animation to complete
        hs.timer.doAfter(T.FULLSCREEN.POST_EXIT_CALLBACK_DELAY, function()
            if callback then callback(app) end
        end)
    end)
end

--------------------------------------------------------------------------------
-- Space Navigation (with retry logic)
--------------------------------------------------------------------------------

local function goto_space_and_wait(space_id, callback, opts)
    opts = opts or {}
    local timeout = opts.timeout or T.SPACE.HOP_TIMEOUT

    -- Fast path: already on target space
    if hs.spaces.activeSpaceOnScreen() == space_id then
        Logger:debug("Already on space %s", tostring(space_id))
        if callback then
            hs.timer.doAfter(T.SPACE.HOP_SETTLE_DELAY, function() callback(true) end)
        end
        return
    end

    Logger:debug("Hopping to space %s", tostring(space_id))

    -- Store operation ID for cancellation check
    local operation_id = state.current_operation_id

    -- Initiate the space change
    local ok, err = pcall(hs.spaces.gotoSpace, space_id)
    if not ok then
        Logger:error("Failed to initiate hop to space %s: %s", tostring(space_id), err)
        if callback then callback(false) end
        return
    end

    -- Poll for arrival
    pollUntil("space_hop", function()
        -- Check if operation was cancelled
        if operation_id and operation_id ~= state.current_operation_id then
            return false
        end
        return hs.spaces.activeSpaceOnScreen() == space_id
    end, {
        interval = T.SPACE.HOP_POLL_INTERVAL,
        timeout = timeout,
        retries = T.SPACE.HOP_MAX_RETRIES,
    }, function(success, _)
        if success then
            Logger:debug("Successfully arrived at space %s", tostring(space_id))
            hs.timer.doAfter(T.SPACE.HOP_SETTLE_DELAY, function()
                if callback then callback(true) end
            end)
        else
            Logger:error("Failed to hop to space %s after retries", tostring(space_id))
            if state.config and state.config.notifications then
                Notifier:showError("Space Navigation", "Could not switch to space " .. tostring(space_id))
            end
            if callback then callback(false) end
        end
    end)
end

--------------------------------------------------------------------------------
-- Window Settling (wait for windows to move to target space)
--------------------------------------------------------------------------------

local function poll_for_window_settling(app, target_space, on_done)
    if not app or not target_space then
        if on_done then on_done(false) end
        return
    end

    local app_name = app:name() or "unknown"

    pollUntil("settle_" .. app_name, function()
        local wins = app:allWindows() or {}
        if #wins == 0 then return false end

        for _, win in ipairs(wins) do
            local ok, spaces = pcall(hs.spaces.windowSpaces, win)
            if not (ok and spaces and #spaces == 1 and spaces[1] == target_space) then
                return false
            end
        end
        return true
    end, {
        interval = T.FULLSCREEN.CREATE_POLL_INTERVAL,
        timeout = T.FULLSCREEN.CREATE_TIMEOUT,
        retries = 1,
    }, function(success, _)
        if success then
            Logger:info("Windows settled for '%s'", app_name)
        else
            Logger:warn("Timeout waiting for '%s' windows to settle", app_name)
        end
        if on_done then on_done(success) end
    end)
end

--------------------------------------------------------------------------------
-- Fullscreen Creation Polling
--------------------------------------------------------------------------------

local function poll_for_fullscreen_creation(win, on_done)
    if not win then
        if on_done then on_done(nil) end
        return
    end

    local win_title = win:title() or "untitled"
    Logger:debug("Waiting for window '%s' to enter fullscreen", win_title)

    pollUntil("fs_create", function()
        local ok, spaces = pcall(hs.spaces.windowSpaces, win)
        if ok and spaces and #spaces == 1 then
            local space_type = hs.spaces.spaceType(spaces[1])
            if space_type == SPACE_TYPES.FULLSCREEN then
                return spaces[1]
            end
        end
        return false
    end, {
        interval = T.FULLSCREEN.CREATE_POLL_INTERVAL,
        timeout = T.FULLSCREEN.CREATE_TIMEOUT,
        retries = 2,
        progress_fn = function(elapsed, timeout)
            if elapsed > timeout * 0.5 then
                Logger:debug("Still waiting for fullscreen... (%.1fs)", elapsed)
            end
        end
    }, function(success, space_id)
        if success and space_id then
            Logger:info("Window '%s' entered fullscreen space %s", win_title, tostring(space_id))
        else
            Logger:error("Failed to create fullscreen for '%s'", win_title)
            if state.config and state.config.notifications then
                Notifier:showError("Fullscreen", "Could not create fullscreen for: " .. win_title)
            end
        end
        if on_done then on_done(space_id) end
    end)
end

--------------------------------------------------------------------------------
-- App Readiness Polling
--------------------------------------------------------------------------------

local function poll_for_apps_ready(apps_to_wait_for, on_done)
    if not apps_to_wait_for or next(apps_to_wait_for) == nil then
        if on_done then on_done(true) end
        return
    end

    local count = 0
    for _ in pairs(apps_to_wait_for) do count = count + 1 end

    Logger:info("Waiting for %d app(s) to launch", count)

    pollUntil("apps_ready", function()
        local remaining = {}
        for bid, _ in pairs(apps_to_wait_for) do
            local app = get_app(bid)
            if not (app and app:isRunning()) then
                remaining[bid] = true
            end
        end

        local ready_count = count - #remaining
        if ready_count > 0 then
            Logger:debug("%d/%d apps ready", ready_count, count)
        end

        return next(remaining) == nil
    end, {
        interval = T.APP.READY_POLL_INTERVAL,
        timeout = T.APP.READY_TIMEOUT,
        retries = 2,
    }, function(success, _)
        if success then
            Logger:info("All apps ready")
        else
            Logger:warn("Some apps failed to launch in time")
            if state.config and state.config.notifications then
                Notifier:showError("App Launch", "Some applications did not start in time")
            end
        end
        if on_done then on_done(success) end
    end)
end

local function poll_for_app_windows(bid_or_app, on_done)
    local bid = type(bid_or_app) == "string" and bid_or_app or
        (bid_or_app.bundleID and bid_or_app:bundleID())

    pollUntil("app_windows_" .. tostring(bid), function()
        local app = type(bid_or_app) == "string" and get_app(bid_or_app) or bid_or_app
        if app and app:isRunning() then
            local wins = app:allWindows()
            if wins and #wins > 0 then
                return app
            end
        end
        return false
    end, {
        interval = T.APP.READY_POLL_INTERVAL,
        timeout = T.APP.WINDOW_POLL_TIMEOUT,
        retries = 1,
    }, function(success, app)
        if on_done then on_done(app) end
    end)
end

--------------------------------------------------------------------------------
-- Screen Management
--------------------------------------------------------------------------------

local function first_space_id(screen)
    local spaces = hs.spaces.spacesForScreen(screen) or {}
    return spaces[1]
end

local function choose_target_screen_name()
    local profiles = state.config.profiles or {}
    local available_screens = hs.screen.allScreens()

    -- Find first screen with a profile
    for _, screen in ipairs(available_screens) do
        local name = screen:name()
        if profiles[name] then
            state.current_screen = screen
            Logger:info("Selected screen '%s' as target", name)
            return name
        end
    end

    -- Fallback to main screen
    local main = hs.screen.mainScreen()
    if main then
        local name = main:name()
        state.current_screen = main
        if profiles[name] then
            Logger:info("Selected main screen '%s' as target", name)
            return name
        else
            Logger:debug("Main screen '%s' has no profile", name)
        end
    end

    Logger:warn("No suitable screen with profile found")
    return nil
end

-- Forward declaration; defined later but referenced by handle_screen_change below.
local scan_and_normalize_spaces

local function handle_screen_change()
    Logger:info("Screen configuration changed")

    local new_screen_name = choose_target_screen_name()
    if new_screen_name ~= state.current_screen_name then
        Logger:info("Screen profile changed: '%s' -> '%s'",
            state.current_screen_name or "none",
            new_screen_name or "none")

        state.current_screen_name = new_screen_name
        M.rebind_hotkeys()

        if state.current_screen_name then
            local profile = state.config.profiles[state.current_screen_name]
            if profile and profile.layouts and #profile.layouts > 0 then
                Logger:info("Auto-applying default layout '%s'", profile.layouts[1].name)
                -- Use longer delay on startup to allow system to stabilize
                local delay = state.config.startup_delay or 0.2
                -- Store timer in state to prevent garbage collection
                state.auto_apply_timer = hs.timer.doAfter(delay, function()
                    Logger:info("Executing auto-apply for '%s' after %.1fs delay", profile.layouts[1].name, delay)
                    -- First scan existing spaces to refresh cache and check current state
                    local target_screen = hs.screen.find(state.current_screen_name)
                    if target_screen then
                        Logger:info("Scanning existing spaces before auto-apply")
                        scan_and_normalize_spaces(target_screen, {}, nil, function()
                            Logger:info("Space scan complete, now applying layout")
                            M.apply_layout(profile.layouts[1])
                        end)
                    else
                        M.apply_layout(profile.layouts[1])
                    end
                    state.auto_apply_timer = nil -- Clear reference after execution
                end)
            end
        end
    end
end

local function schedule_screen_change_handler()
    if state.debounce_timer then
        state.debounce_timer:stop()
    end
    state.debounce_timer = hs.timer.doAfter(T.UI.SCREEN_DEBOUNCE_DELAY, handle_screen_change)
end

--------------------------------------------------------------------------------
-- Hotkey Management
--------------------------------------------------------------------------------

function M.rebind_hotkeys()
    -- Clear existing hotkeys
    for _, hk in ipairs(state.active_hotkeys) do
        hk:delete()
    end
    state.active_hotkeys = {}

    if not state.current_screen_name then return end

    local profile = state.config.profiles[state.current_screen_name]
    if not (profile and profile.layouts) then return end

    for _, layout in ipairs(profile.layouts) do
        if layout.hotkey then
            local mods, key = layout.hotkey.mods, layout.hotkey.key
            local bound = hs.hotkey.bind(mods, key, function()
                Logger:info("Hotkey triggered for layout '%s'", layout.name)
                M.apply_layout(layout)
            end)
            table.insert(state.active_hotkeys, bound)
            Logger:debug("Bound %s-%s for layout '%s'",
                table.concat(mods, "+"), key, layout.name)
        end
    end
end

--------------------------------------------------------------------------------
-- Space Cache Management
--------------------------------------------------------------------------------

local function update_space_cache()
    if state.is_discovering_spaces then return end

    local front = hs.window.frontmostWindow()
    if not front then return end

    local app = front:application()
    if not app then return end

    local bid = app:bundleID()
    local ok, space_id = pcall(hs.spaces.activeSpaceOnScreen)
    if not (ok and space_id) then return end

    local typ_ok, typ = pcall(hs.spaces.spaceType, space_id)
    local now = hs.timer.secondsSinceEpoch()

    local prev = state.model.spaces[space_id] or {}
    if prev.occupantBid ~= bid or prev.type ~= typ then
        state.model.spaces[space_id] = {
            type = typ_ok and typ or nil,
            occupantBid = bid,
            timestamp = now
        }
        Logger:debug("Cache update: space %s -> %s (type=%s)",
            tostring(space_id), tostring(bid), tostring(typ))
    end
end

local function invalidate_stale_cache()
    local now = hs.timer.secondsSinceEpoch()
    local stale = {}

    for sid, data in pairs(state.model.spaces) do
        if data.timestamp and (now - data.timestamp) > T.PERF.CACHE_TTL_SECONDS then
            table.insert(stale, sid)
        end
    end

    for _, sid in ipairs(stale) do
        state.model.spaces[sid] = nil
        Logger:debug("Invalidated stale cache for space %s", tostring(sid))
    end
end

-- Drop cache entries whose occupant app is no longer running. Called on app
-- termination so a quit fullscreen app's stale Space entry can't mislead a scan.
local function prune_terminated_from_cache()
    for sid, data in pairs(state.model.spaces) do
        if data.occupantBid and not get_app(data.occupantBid) then
            state.model.spaces[sid] = nil
            Logger:debug("Pruned cache for terminated app: space %s -> %s",
                tostring(sid), tostring(data.occupantBid))
        end
    end
end

--------------------------------------------------------------------------------
-- Tile Frame Calculation
--------------------------------------------------------------------------------

local function compute_tile_frame(tile_spec, screen)
    local frame = screen:frame()
    local w, h

    if tile_spec.w and tile_spec.h then
        w, h = tile_spec.w, tile_spec.h
    else
        w = frame.w * (tile_spec.wPct or 1.0)
        h = frame.h * (tile_spec.hPct or 1.0)
    end

    local anchor = tile_spec.anchor or "center"
    local x, y = frame.x, frame.y

    -- Vertical anchor
    if anchor:find("top") then
        y = frame.y
    elseif anchor:find("bottom") then
        y = frame.y + frame.h - h
    else
        y = frame.y + (frame.h - h) / 2
    end

    -- Horizontal anchor
    if anchor:find("left") then
        x = frame.x
    elseif anchor:find("right") then
        x = frame.x + frame.w - w
    else
        x = frame.x + (frame.w - w) / 2
    end

    -- Validate frame is within screen bounds
    x = math.max(frame.x, math.min(x, frame.x + frame.w - w))
    y = math.max(frame.y, math.min(y, frame.y + frame.h - h))

    return hs.geometry.rect(x, y, w, h)
end

--------------------------------------------------------------------------------
-- Layout Parsing (split into smaller functions)
--------------------------------------------------------------------------------

local function validate_layout(layout)
    if not layout then
        return false, "Layout is nil"
    end
    if type(layout) ~= "table" then
        return false, "Layout must be a table"
    end
    if layout.space_layouts and type(layout.space_layouts) ~= "table" then
        return false, "space_layouts must be a table"
    end
    return true
end

local function parse_tiling_spec(space_spec, tiles_def, result)
    if not space_spec or type(space_spec) ~= "table" then
        return
    end

    -- Check if it's a tile map
    local is_tile_map = false
    for k, _ in pairs(space_spec) do
        if type(k) == "string" and tiles_def[k] then
            is_tile_map = true
            break
        end
    end

    if not is_tile_map then
        Logger:warn("Space 1 should contain tile mappings")
        return
    end

    for tileName, bundleList in pairs(space_spec) do
        if tiles_def[tileName] then
            local arr = {}
            for _, bid in ipairs(to_array(bundleList)) do
                arr[#arr + 1] = bid
                result.tilingSet[bid] = true
                result.allBundles[bid] = true
            end
            result.tiling[tileName] = arr
        else
            Logger:warn("Tile '%s' not defined in profile", tileName)
        end
    end
end

local function parse_fullscreen_spec(space_layouts, result)
    -- Collect and sort fullscreen space indices
    local fs_keys = {}
    for spaceIndex, _ in pairs(space_layouts) do
        if type(spaceIndex) == "number" and spaceIndex > 1 then
            table.insert(fs_keys, spaceIndex)
        end
    end
    table.sort(fs_keys)

    -- Process in order
    for _, spaceIndex in ipairs(fs_keys) do
        local spec = space_layouts[spaceIndex]
        if type(spec) == "table" then
            for _, bid in ipairs(spec) do
                result.fullscreenOrder[#result.fullscreenOrder + 1] = bid
                result.allBundles[bid] = true
            end
        end
    end
end

local function parse_layout(layout, profile)
    local result = {
        tiling = {},          -- tileName -> { bundleIDs }
        fullscreenOrder = {}, -- ordered list of bundleIDs
        tilingSet = {},       -- set of bundleIDs in tiles
        allBundles = {},      -- set of all bundleIDs
        focusApp = layout.focusApp,
    }

    if not layout.space_layouts then
        return result
    end

    local tiles_def = (profile and profile.tiles) or {}

    -- Parse tiling (space 1)
    if layout.space_layouts[1] then
        parse_tiling_spec(layout.space_layouts[1], tiles_def, result)
    end

    -- Parse fullscreen (spaces 2+)
    parse_fullscreen_spec(layout.space_layouts, result)

    return result
end

--------------------------------------------------------------------------------
-- Window Collection and Management
--------------------------------------------------------------------------------

local function collect_app_windows(bundleSet)
    local mapping = {}
    for bid, _ in pairs(bundleSet) do
        local app = get_app(bid)
        if app and app:isRunning() then
            mapping[bid] = {
                app = app,
                windows = app:allWindows() or {}
            }
        else
            mapping[bid] = {
                app = nil,
                windows = {}
            }
        end
    end
    return mapping
end

local function expand_fullscreen_order_block(baseOrder, appWindows)
    if not baseOrder or #baseOrder == 0 then return {} end

    -- Count usable windows per app
    local counts = {}
    for _, bid in ipairs(baseOrder) do
        local entry = appWindows and appWindows[bid]
        local count = 0
        if entry and entry.windows then
            for _, w in ipairs(entry.windows) do
                if w:isStandard() and not w:isMinimized() then
                    count = count + 1
                end
            end
        end
        counts[bid] = count
    end

    -- Find max count
    local maxCount = 0
    for _, count in pairs(counts) do
        if count > maxCount then maxCount = count end
    end

    if maxCount == 0 then
        return baseOrder -- Return as-is if no windows yet
    end

    -- Expand based on window counts
    local expanded = {}
    for _, bid in ipairs(baseOrder) do
        local n = counts[bid] or 0
        for i = 1, n do
            expanded[#expanded + 1] = bid
        end
    end

    return #expanded > 0 and expanded or baseOrder
end



--------------------------------------------------------------------------------
-- Window Tiling
--------------------------------------------------------------------------------

local function apply_tiling(tilingMap, appWindows, target_screen)
    if not target_screen then
        Logger:error("No target screen for tiling")
        return 0
    end

    local first_space = first_space_id(target_screen)
    if not first_space then
        Logger:error("No first space found for tiling")
        return 0
    end

    local profile = state.config.profiles[state.current_screen_name]
    local tiles_def = (profile and profile.tiles) or {}
    local moves = 0
    local errors = 0

    for tileName, bundleIDs in pairs(tilingMap) do
        local tile_spec = tiles_def[tileName]
        if not tile_spec then
            Logger:warn("Tile '%s' has no spec", tileName)
        else
            local frame = compute_tile_frame(tile_spec, target_screen)

            for _, bid in ipairs(bundleIDs) do
                local entry = appWindows[bid]
                if entry and entry.app and entry.app:isRunning() then
                    local tiled = 0

                    for _, win in ipairs(entry.windows or {}) do
                        if win:isStandard() and not win:isMinimized() and not is_effectively_fullscreen(win) then
                            -- Move to target screen
                            if win:screen() ~= target_screen then
                                local ok = pcall(function() win:moveToScreen(target_screen, false, true) end)
                                if not ok then errors = errors + 1 end
                            end

                            -- Move to first space
                            local ok = pcall(function() hs.spaces.moveWindowToSpace(win, first_space) end)
                            if not ok then errors = errors + 1 end

                            -- Apply frame
                            ok = pcall(function() win:setFrame(frame) end)
                            if ok then
                                moves = moves + 1
                                tiled = tiled + 1
                            else
                                errors = errors + 1
                            end
                        end
                    end

                    if tiled > 0 then
                        Logger:debug("Tiled %d windows for '%s' to %s", tiled, bid, tileName)
                    end
                elseif entry and entry.app then
                    Logger:debug("No tileable windows for '%s'", bid)
                end
            end
        end
    end

    if errors > 0 then
        Logger:warn("Tiling completed with %d errors", errors)
    end

    return moves
end

--------------------------------------------------------------------------------
-- Fullscreen Management (Split into smaller functions)
--------------------------------------------------------------------------------

local function find_unused_fullscreen_window(win_list, used_windows_map)
    for _, w in ipairs(win_list or {}) do
        if not used_windows_map[w:id()] and is_effectively_fullscreen(w) then
            local ok, spaces = pcall(hs.spaces.windowSpaces, w)
            local sid = ok and spaces and spaces[1] or nil
            if sid then
                return w, sid
            end
        end
    end
    return nil, nil
end

local function select_window_for_fullscreen(windows, used_windows, first_space, active_space)
    -- First pass: prefer windows on active or main space
    for _, w in ipairs(windows) do
        if not used_windows[w:id()] and w:isStandard() and not w:isMinimized() and not is_effectively_fullscreen(w) then
            local ok, spaces = pcall(hs.spaces.windowSpaces, w)
            local sid = ok and spaces and spaces[1] or nil
            if sid == active_space or sid == first_space then
                return w
            end
        end
    end

    -- Second pass: any suitable window
    for _, w in ipairs(windows) do
        if not used_windows[w:id()] and w:isStandard() and not w:isMinimized() and not is_effectively_fullscreen(w) then
            return w
        end
    end

    return nil
end

local function make_window_fullscreen(win, bid, callback)
    if not win then
        if callback then callback(nil) end
        return
    end

    -- Unminimize if needed
    if win:isMinimized() then
        pcall(function() win:unminimize() end)
    end

    -- Focus window
    pcall(function() win:focus() end)

    -- Delay then set fullscreen
    hs.timer.doAfter(T.FULLSCREEN.SET_DELAY, function()
        Logger:debug("Setting fullscreen for '%s' window", bid)
        local ok = pcall(function() win:setFullScreen(true) end)
        if not ok then
            Logger:error("Failed to set fullscreen for '%s'", bid)
        end
        poll_for_fullscreen_creation(win, callback)
    end)
end

local function apply_fullscreen(fullscreenOrder, appWindows, target_screen, on_done)
    if not fullscreenOrder or #fullscreenOrder == 0 then
        state.is_discovering_spaces = false
        if on_done then on_done({}) end
        return
    end

    state.is_discovering_spaces = true
    local total = #fullscreenOrder
    local new_space_ids = {}
    local used_windows = {}
    local first_space = first_space_id(target_screen)
    local errors = 0

    Logger:info("Creating %d fullscreen spaces", total)

    local idx = 1
    local operation_id = state.current_operation_id

    local function process_next(new_sid, was_adopted, bid)
        -- Check if operation was cancelled
        if operation_id ~= state.current_operation_id then
            Logger:debug("Fullscreen operation cancelled")
            return
        end

        if new_sid then
            table.insert(new_space_ids, new_sid)
            -- Cache the space immediately since we know what app it contains
            if bid then
                state.model.spaces[new_sid] = {
                    type = SPACE_TYPES.FULLSCREEN,
                    occupantBid = bid,
                    timestamp = hs.timer.secondsSinceEpoch()
                }
                Logger:debug("Cached new fullscreen space %s -> %s", tostring(new_sid), bid)
            end
            -- After creating a new fullscreen, macOS switches to the fullscreen space
            -- We need to switch back to first space before processing next window
            -- But if we adopted an existing fullscreen, we're still on first space
            -- Also skip hop if this was the last window
            if not was_adopted and idx <= #fullscreenOrder and hs.spaces.activeSpaceOnScreen() ~= first_space then
                Logger:debug("Fullscreen created (space %s), returning to first space", tostring(new_sid))
                goto_space_and_wait(first_space, function(success)
                    if not success then
                        Logger:warn("Failed to return to first space after fullscreen")
                    end
                    -- Continue with next window from correct space
                    hs.timer.doAfter(0.1, function()
                        process_next(nil)
                    end)
                end)
                return
            elseif was_adopted then
                Logger:debug("Adopted existing fullscreen (space %s), continuing from current space", tostring(new_sid))
            elseif idx > #fullscreenOrder then
                Logger:debug("Last fullscreen created (space %s), staying in current space", tostring(new_sid))
            end
        end

        if idx > #fullscreenOrder then
            state.is_discovering_spaces = false
            Logger:info("Fullscreen creation complete (%d spaces, %d errors)", #new_space_ids, errors)
            if errors > 0 and state.config and state.config.notifications then
                Notifier:show("Layout Applied",
                    string.format("Created %d fullscreen spaces with %d errors", #new_space_ids, errors),
                    NOTIFICATION_TYPES.WARNING)
            end
            if on_done then on_done(new_space_ids) end
            return
        end

        local bid = fullscreenOrder[idx]
        idx = idx + 1

        -- Show progress
        if total > 2 and state.config and state.config.notifications then
            Notifier:showProgress("Creating fullscreen spaces", idx - 1, total)
        end

        -- Get app and windows (refresh from fullscreen spaces)
        local entry = appWindows[bid] or {}
        if not entry.app then
            entry.app = get_app(bid)
        end

        if entry.app and entry.app:isRunning() then
            -- Force refresh windows including those in fullscreen spaces
            local fresh_windows = entry.app:allWindows() or {}
            -- Merge with existing windows to not lose any
            local win_map = {}
            for _, w in ipairs(entry.windows or {}) do
                local ok, id = pcall(function() return w:id() end)
                if ok and id then win_map[id] = w end
            end
            for _, w in ipairs(fresh_windows) do
                local ok, id = pcall(function() return w:id() end)
                if ok and id then win_map[id] = w end
            end
            local merged = {}
            for _, w in pairs(win_map) do
                table.insert(merged, w)
            end
            entry.windows = merged
        end

        appWindows[bid] = entry

        if not entry.app then
            Logger:info("Waiting for '%s' to launch", bid)
            return poll_for_app_windows(bid, function(app)
                if app then
                    appWindows[bid] = { app = app, windows = app:allWindows() or {} }
                    table.insert(fullscreenOrder, bid) -- Re-queue
                end
                process_next(nil)
            end)
        end

        if not entry.windows or #entry.windows == 0 then
            Logger:debug("No windows for '%s', skipping", bid)
            return process_next(nil)
        end

        -- Try to adopt existing fullscreen window
        local adopted_win, adopted_sid = find_unused_fullscreen_window(entry.windows, used_windows)
        if adopted_win then
            Logger:debug("Adopting existing fullscreen for '%s'", bid)
            used_windows[adopted_win:id()] = true

            -- Update cache for adopted space
            if adopted_sid then
                state.model.spaces[adopted_sid] = {
                    type = SPACE_TYPES.FULLSCREEN,
                    occupantBid = bid,
                    timestamp = hs.timer.secondsSinceEpoch()
                }
                Logger:debug("Updated cache for adopted space %s -> %s", tostring(adopted_sid), bid)
            end

            -- Check for more windows to process
            local has_more = false
            for _, w in ipairs(entry.windows) do
                if not used_windows[w:id()] and w:isStandard() and not w:isMinimized() then
                    has_more = true
                    break
                end
            end
            if has_more then
                table.insert(fullscreenOrder, bid)
            end

            return process_next(adopted_sid, true, bid) -- true = was adopted, pass bid for caching
        end

        -- Select and create new fullscreen
        -- Ensure we're in the first space before creating fullscreen
        local active_space = hs.spaces.activeSpaceOnScreen(target_screen)
        if active_space ~= first_space then
            Logger:debug("Switching to first space before creating fullscreen")
            goto_space_and_wait(first_space, function(success)
                if not success then
                    Logger:warn("Could not switch to first space, continuing anyway")
                end
                process_next(nil) -- Retry from the correct space
            end)
            return
        end

        local win = select_window_for_fullscreen(entry.windows, used_windows, first_space, active_space)

        if not win then
            Logger:warn("No suitable window for fullscreen: '%s'", bid)
            errors = errors + 1
            return process_next(nil)
        end

        used_windows[win:id()] = true

        -- Check for additional windows
        local has_more = false
        for _, w in ipairs(entry.windows) do
            if not used_windows[w:id()] and w:isStandard() and not w:isMinimized() then
                has_more = true
                break
            end
        end
        if has_more then
            table.insert(fullscreenOrder, bid)
        end

        -- Move to target screen if needed
        if target_screen and win:screen() ~= target_screen then
            pcall(function() win:moveToScreen(target_screen, false, true) end)
        end

        -- Check if already fullscreen
        if is_effectively_fullscreen(win) then
            local ok, spaces = pcall(hs.spaces.windowSpaces, win)
            local sid = ok and spaces and spaces[1] or nil
            Logger:debug("Window already fullscreen for '%s'", bid)
            return process_next(sid, true, bid) -- true = already fullscreen, so adopted, pass bid
        end

        -- Move to active space and create fullscreen
        local ok, win_spaces = pcall(hs.spaces.windowSpaces, win)
        local win_space = ok and win_spaces and win_spaces[1] or nil

        if win_space and win_space ~= active_space then
            pcall(function() hs.spaces.moveWindowToSpace(win, active_space) end)
        end

        make_window_fullscreen(win, bid, function(new_sid)
            process_next(new_sid, false, bid) -- false = not adopted, pass bid for caching
        end)
    end

    process_next()
end

--------------------------------------------------------------------------------
-- Space Scanning and Normalization
--------------------------------------------------------------------------------

scan_and_normalize_spaces = function(target_screen, tilingSet, appWindows, callback)
    local screen_spaces = hs.spaces.spacesForScreen(target_screen) or {}
    local fullscreen_spaces = {}
    local all_known = true

    for _, sid in ipairs(screen_spaces) do
        if hs.spaces.spaceType(sid) == SPACE_TYPES.FULLSCREEN then
            table.insert(fullscreen_spaces, sid)
            if not state.model.spaces[sid] then
                all_known = false
            end
        end
    end

    -- Even if all spaces are cached, we still need to check for normalization
    local needs_normalization = false
    if all_known and #fullscreen_spaces > 0 then
        -- Check if any cached fullscreen spaces contain apps that should be tiled
        for _, sid in ipairs(fullscreen_spaces) do
            local cache_entry = state.model.spaces[sid]
            if cache_entry and cache_entry.occupantBid and tilingSet[cache_entry.occupantBid] then
                needs_normalization = true
                break
            end
        end

        if not needs_normalization then
            Logger:debug("All %d fullscreen spaces cached, no normalization needed", #fullscreen_spaces)
            -- Update appWindows with cached fullscreen apps if provided
            if appWindows then
                for _, sid in ipairs(fullscreen_spaces) do
                    local cache_entry = state.model.spaces[sid]
                    if cache_entry and cache_entry.occupantBid then
                        local bid = cache_entry.occupantBid
                        local app = get_app(bid)
                        if app then
                            if not appWindows[bid] then
                                appWindows[bid] = { app = app, windows = {} }
                            end
                            -- Refresh windows for this app
                            local windows = app:allWindows() or {}
                            appWindows[bid].windows = windows
                            Logger:debug("Refreshed %d windows for '%s' from cache", #windows, bid)
                        end
                    end
                end
            end
            return callback()
        else
            Logger:debug("All %d fullscreen spaces cached, but normalization needed", #fullscreen_spaces)
        end
    end

    if #fullscreen_spaces == 0 then
        state.is_discovering_spaces = false
        return callback()
    end

    state.is_discovering_spaces = true
    local operation_id = state.current_operation_id

    if all_known and needs_normalization then
        Logger:info("Normalizing %d fullscreen spaces", #fullscreen_spaces)
    else
        Logger:info("Scanning %d fullscreen spaces", #fullscreen_spaces)
    end

    local original_space = hs.spaces.activeSpaceOnScreen()
    local i = 1
    local normalized = 0

    local function process_space()
        -- Check if operation was cancelled
        if state.current_operation_id and operation_id ~= state.current_operation_id then
            Logger:debug("Space scan operation cancelled")
            state.is_discovering_spaces = false
            return
        end

        if i > #fullscreen_spaces then
            state.is_discovering_spaces = false
            Logger:info("Scan complete, normalized %d spaces", normalized)

            -- Return to first user space, not original (which may have been removed)
            local first_space = first_space_id(target_screen)
            if first_space and hs.spaces.activeSpaceOnScreen() ~= first_space then
                return goto_space_and_wait(first_space, callback)
            else
                return callback()
            end
        end

        local sid = fullscreen_spaces[i]
        i = i + 1

        -- Verify space still exists
        local exists = false
        for _, s in ipairs(hs.spaces.spacesForScreen(target_screen) or {}) do
            if s == sid then
                exists = true
                break
            end
        end

        if not exists then
            Logger:warn("Space %s no longer exists", tostring(sid))
            return process_space()
        end

        -- Check if we already know about this space and if it needs normalization
        local cached_entry = state.model.spaces[sid]
        local needs_visit = false
        local needs_normalize = false

        if not cached_entry then
            -- Not cached, need to visit to discover
            needs_visit = true
        elseif cached_entry.occupantBid and tilingSet[cached_entry.occupantBid] then
            -- Cached and needs normalization
            needs_visit = true
            needs_normalize = true
        end

        if not needs_visit then
            -- Skip this space, it's cached and doesn't need normalization
            Logger:debug("Skipping space %s (cached, no normalization needed)", tostring(sid))
            return process_space()
        end

        -- Hop to the space once: update cache and/or normalize if needed.
        goto_space_and_wait(sid, function(success)
            if not success then
                return process_space()
            end

            local front = hs.window.frontmostWindow()
            if front and front:application() then
                local app = front:application()
                local bid = app:bundleID()

                if bid then
                    -- Update cache if not already cached or if data changed
                    if not cached_entry or cached_entry.occupantBid ~= bid then
                        state.model.spaces[sid] = {
                            type = SPACE_TYPES.FULLSCREEN,
                            occupantBid = bid,
                            timestamp = hs.timer.secondsSinceEpoch()
                        }
                        Logger:debug("Cached space %s -> %s", tostring(sid), bid)
                    end

                    -- Force refresh windows for this app to include fullscreen ones
                    if appWindows then
                        if not appWindows[bid] then
                            appWindows[bid] = { app = app, windows = {} }
                        else
                            appWindows[bid].app = app
                        end
                        -- Get all windows for this app, including fullscreen ones
                        local windows = app:allWindows() or {}
                        appWindows[bid].windows = windows
                        Logger:debug("Refreshed %d windows for '%s' in fullscreen space", #windows, bid)
                    end
                end

                if bid and tilingSet[bid] then
                    Logger:info("[Normalize] Space %s occupant '%s' should be tiled; exiting fullscreen.",
                        tostring(sid), tostring(bid))
                    normalized = normalized + 1

                    -- Ensure we have the front window focused before trying to exit fullscreen
                    if front then
                        pcall(function() front:focus() end)
                        hs.timer.doAfter(0.1, function()
                            exit_fullscreen_for_app(app, function()
                                local first_space = first_space_id(target_screen)
                                poll_for_window_settling(app, first_space, process_space)
                            end)
                        end)
                    else
                        exit_fullscreen_for_app(app, function()
                            local first_space = first_space_id(target_screen)
                            poll_for_window_settling(app, first_space, process_space)
                        end)
                    end
                    return
                end
            else
                Logger:debug("No frontmost window on space %s", tostring(sid))
            end

            process_space()
        end, { timeout = T.SPACE.HOP_TIMEOUT * 2 }) -- Give more time during scan
    end

    process_space()
end

--------------------------------------------------------------------------------
-- Main Layout Application
--------------------------------------------------------------------------------

function M.apply_layout(layout)
    -- Validation
    local valid, err = validate_layout(layout)
    if not valid then
        Logger:error("Invalid layout: %s", err)
        if state.config and state.config.notifications then
            Notifier:showError("Layout Error", err)
        end
        return
    end

    -- Cancel any ongoing layout application
    if state.is_applying then
        Logger:info("Interrupting current layout for '%s'", layout.name or "unnamed")
        state.current_operation_id = generate_operation_id() -- Cancel ongoing operations
        cleanup_all_operations()
        state.is_applying = false
        state.is_discovering_spaces = false
        -- Store the layout to apply after cleanup
        state._pending_layout = layout
        -- Longer delay to let windows settle after interruption
        hs.timer.doAfter(0.3, function()
            local pending = state._pending_layout
            state._pending_layout = nil
            if pending then
                M.apply_layout(pending)
            end
        end)
        return
    end

    if not state.current_screen_name then
        Logger:error("No screen profile selected")
        if state.config and state.config.notifications then
            Notifier:showError("Layout Error", "No screen profile selected")
        end
        return
    end

    local profile = state.config.profiles[state.current_screen_name]
    if not profile then
        Logger:error("Profile not found for screen '%s'", state.current_screen_name)
        if state.config and state.config.notifications then
            Notifier:showError("Layout Error", "Profile not found")
        end
        return
    end

    -- Begin layout application
    state.is_applying = true
    local layout_name = layout.name or "unnamed"

    -- Generate operation ID for this layout application (after validation)
    local operation_id = generate_operation_id()
    state.current_operation_id = operation_id
    Logger:info("Applying layout '%s' for screen '%s'", layout_name, state.current_screen_name)
    if state.config and state.config.notifications then
        Notifier:show("Applying Layout", "Starting: " .. layout_name, NOTIFICATION_TYPES.INFO)
    end

    -- Disable animations for speed
    local original_animation = hs.window.animationDuration
    hs.window.animationDuration = 0

    -- Bail out of a superseded layout (a newer one took over), restoring the saved
    -- animation setting. Returns true if this op was cancelled, so callers can
    -- `if abort_if_cancelled(...) then return end` before doing more work.
    local function abort_if_cancelled(where)
        if operation_id ~= state.current_operation_id then
            Logger:debug("Layout application cancelled %s", where)
            hs.window.animationDuration = original_animation
            return true
        end
        return false
    end

    -- Parse layout
    local parsed = parse_layout(layout, profile)

    -- Get all bundle IDs
    local all_bundles = {}
    for bid, _ in pairs(parsed.allBundles) do
        table.insert(all_bundles, bid)
    end

    -- Ensure apps are running
    local apps_to_launch = ensure_apps_running(all_bundles, #all_bundles > 3)

    -- Wait for apps to be ready
    -- Wait for apps to launch
    poll_for_apps_ready(apps_to_launch, function(apps_ready)
        if not apps_ready then
            Logger:warn("Some apps failed to launch")
        end

        -- Get target screen
        local target_screen = state.current_screen or hs.screen.find(state.current_screen_name)
        if not target_screen then
            Logger:error("Target screen not found")
            state.is_applying = false
            hs.window.animationDuration = original_animation
            if state.config and state.config.notifications then
                Notifier:showError("Layout Error", "Target screen not found")
            end
            return
        end

        -- Collect initial windows (force refresh for all apps to catch windows from interrupted layouts)
        local appWindows = {}
        for bid, _ in pairs(parsed.allBundles) do
            local app = get_app(bid)
            if app then
                -- Force refresh all windows for this app
                appWindows[bid] = {
                    app = app,
                    windows = app:allWindows() or {}
                }
                Logger:debug("Collected %d windows for %s", #appWindows[bid].windows, bid)
            end
        end

        -- Phase 1: Scan and normalize existing fullscreen spaces
        scan_and_normalize_spaces(target_screen, parsed.tilingSet, appWindows, function()
            -- Bail if a newer layout superseded us during the space scan.
            if abort_if_cancelled("after space scan") then return end
            -- Phase 2: Apply tiling (refresh collection after scan)
            -- Re-collect all windows to catch any that were moved out of fullscreen
            for bid, _ in pairs(parsed.allBundles) do
                local app = get_app(bid)
                if app then
                    local fresh_windows = app:allWindows() or {}
                    if #fresh_windows > 0 then
                        if not appWindows[bid] then
                            appWindows[bid] = { app = app, windows = {} }
                        end
                        appWindows[bid].windows = fresh_windows
                        Logger:debug("Refreshed %d windows for %s after scan", #fresh_windows, bid)
                    elseif appWindows[bid] and #appWindows[bid].windows > 0 then
                        -- Keep existing windows if fresh collection found none
                        Logger:debug("Keeping %d windows for %s from scan", #appWindows[bid].windows, bid)
                    end
                end
            end

            -- Skip tiling if superseded during the post-scan window re-collection.
            if abort_if_cancelled("before tiling") then return end
            local tiles_moved = apply_tiling(parsed.tiling, appWindows, target_screen)

            local function complete_layout()
                if abort_if_cancelled("before completion") then return end
                -- Phase 3: Apply fullscreen (use existing appWindows, don't re-collect)
                -- Windows are already collected from scan and tiling phases
                local fs_order = expand_fullscreen_order_block(parsed.fullscreenOrder, appWindows)

                -- Reverse order for deterministic creation
                local fs_reversed = {}
                for i = #fs_order, 1, -1 do
                    fs_reversed[#fs_reversed + 1] = fs_order[i]
                end

                apply_fullscreen(fs_reversed, appWindows, target_screen, function(new_spaces)
                    -- Focus requested app
                    if parsed.focusApp then
                        local entry = appWindows[parsed.focusApp]
                        if entry and entry.app then
                            local win = entry.app:mainWindow() or entry.app:focusedWindow()
                            if win then
                                pcall(function() win:focus() end)
                            end
                        end
                    end

                    -- Clean up
                    state.is_applying = false
                    hs.window.animationDuration = original_animation
                    invalidate_stale_cache()

                    Logger:info("Layout '%s' complete", layout_name)
                    if state.config and state.config.notifications then
                        Notifier:show("Layout Complete", layout_name .. " applied successfully", NOTIFICATION_TYPES.INFO)
                    end
                end)
            end

            -- If we moved tiles, do a second pass after a delay
            if tiles_moved > 0 then
                Logger:debug("Second tiling pass in %.1fs", T.UI.SECOND_TILING_PASS_DELAY)
                hs.timer.doAfter(T.UI.SECOND_TILING_PASS_DELAY, function()
                    -- Skip the second pass entirely if a newer layout superseded us.
                    if abort_if_cancelled("before second tiling pass") then return end
                    -- Only refresh windows for tiled apps
                    for tileName, bundleIDs in pairs(parsed.tiling) do
                        for _, bid in ipairs(bundleIDs) do
                            local app = get_app(bid)
                            if app and appWindows[bid] then
                                appWindows[bid].windows = app:allWindows() or {}
                            end
                        end
                    end
                    apply_tiling(parsed.tiling, appWindows, target_screen)
                    complete_layout()
                end)
            else
                complete_layout()
            end
        end)
    end)
end

--------------------------------------------------------------------------------
-- Module Setup and Teardown
--------------------------------------------------------------------------------

function M.setup(config)
    Logger:init(config and config.debug)
    Logger:info("Setting up window manager")

    -- Clean up any existing state
    if state.screen_watcher or state.space_watcher or (#state.active_hotkeys > 0) then
        M.teardown()
    end

    state.config = config
    hs.window.animationDuration = 0

    -- Start screen watcher
    state.screen_watcher = hs.screen.watcher.new(schedule_screen_change_handler)
    state.screen_watcher:start()

    -- Start space watcher
    state.space_watcher = hs.spaces.watcher.new(update_space_cache)
    state.space_watcher:start()

    -- Start app watcher to evict cache entries when their app quits
    state.app_watcher = hs.application.watcher.new(function(_, eventType)
        if eventType == hs.application.watcher.terminated then
            prune_terminated_from_cache()
        end
    end)
    state.app_watcher:start()

    -- Initial setup
    handle_screen_change()

    Logger:info("Window manager setup complete")
end

function M.teardown()
    Logger:info("Tearing down window manager")

    -- Clean up all active operations
    cleanup_all_operations()

    -- Stop watchers
    if state.screen_watcher then
        state.screen_watcher:stop()
        state.screen_watcher = nil
    end

    if state.space_watcher then
        state.space_watcher:stop()
        state.space_watcher = nil
    end

    if state.app_watcher then
        state.app_watcher:stop()
        state.app_watcher = nil
    end

    -- Cancel timers
    if state.debounce_timer then
        state.debounce_timer:stop()
        state.debounce_timer = nil
    end

    -- Cancel any pending auto-apply timer
    if state.auto_apply_timer then
        state.auto_apply_timer:stop()
        state.auto_apply_timer = nil
    end

    -- Delete hotkeys
    for _, hk in ipairs(state.active_hotkeys) do
        hk:delete()
    end
    state.active_hotkeys = {}

    -- Clear notification
    if state.last_notification then
        pcall(function() state.last_notification:withdraw() end)
        state.last_notification = nil
    end

    -- Reset flags
    state.is_applying = false
    state.is_discovering_spaces = false

    Logger:info("Window manager teardown complete")
end

function M.status()
    local cache_lines = {}
    for sid, meta in pairs(state.model.spaces) do
        local age = meta.timestamp and
            (hs.timer.secondsSinceEpoch() - meta.timestamp) or 0
        table.insert(cache_lines, string.format(
            "  %s -> %s (type=%s, age=%.0fs)",
            tostring(sid),
            tostring(meta.occupantBid),
            tostring(meta.type),
            age
        ))
    end
    table.sort(cache_lines)

    -- Count active operations (it's a dictionary, not array)
    local active_ops_count = 0
    for _ in pairs(state.active_operations) do
        active_ops_count = active_ops_count + 1
    end

    local report = {
        string.format("Screen: %s", state.current_screen_name or "none"),
        string.format("Is Applying: %s", tostring(state.is_applying)),
        string.format("Active Hotkeys: %d", #state.active_hotkeys),
        string.format("Screen Watcher: %s", state.screen_watcher and "active" or "inactive"),
        string.format("Space Watcher: %s", state.space_watcher and "active" or "inactive"),
        string.format("Active Operations: %d", active_ops_count),
        "Space Cache:"
    }

    for _, line in ipairs(cache_lines) do
        table.insert(report, line)
    end

    return table.concat(report, "\n")
end

--------------------------------------------------------------------------------
-- Spoon API Wrapper
--------------------------------------------------------------------------------

--- WindowManager:init()
--- Method
--- Initialize the WindowManager spoon
---
--- Parameters:
---  * None
---
--- Returns:
---  * The WindowManager object
function obj:init()
    return self
end

--- WindowManager:configure(config)
--- Method
--- Configure the WindowManager with profiles and layouts
---
--- Parameters:
---  * config - A table containing configuration with:
---    * debug - boolean, enable debug logging (default: false)
---    * notifications - boolean, enable notifications (default: true)
---    * profiles - table of screen name to profile mappings, each profile contains:
---      * tiles - table of tile definitions with anchor, w/h or wPct/hPct
---      * layouts - array of layout definitions with:
---        * name - string, layout name
---        * hotkey - table with mods and key for hotkey binding
---        * space_layouts - table with space index to app bundle ID mappings
---        * focusApp - optional bundle ID of app to focus after layout
---
--- Returns:
---  * The WindowManager object
function obj:configure(config)
    self._config = config
    return self
end

--- WindowManager:start()
--- Method
--- Start the WindowManager
---
--- Parameters:
---  * None
---
--- Returns:
---  * The WindowManager object
function obj:start()
    M.setup(self._config)
    return self
end

--- WindowManager:stop()
--- Method
--- Stop the WindowManager
---
--- Parameters:
---  * None
---
--- Returns:
---  * The WindowManager object
function obj:stop()
    M.teardown()
    return self
end

--- WindowManager:bindHotkeys(mapping)
--- Method
--- Bind hotkeys for WindowManager
---
--- Parameters:
---  * mapping - A table with hotkey mappings (currently unused, hotkeys are defined in layouts)
---
--- Returns:
---  * The WindowManager object
---
--- Notes:
---  * This method exists for API consistency but hotkeys are actually defined in the layout configuration
function obj:bindHotkeys(mapping)
    -- Hotkeys are defined in the layout configuration
    return self
end

--- WindowManager:apply_layout(layout)
--- Method
--- Apply a specific layout
---
--- Parameters:
---  * layout - A layout table with space_layouts specification
---
--- Returns:
---  * The WindowManager object
function obj:apply_layout(layout)
    M.apply_layout(layout)
    return self
end

--- WindowManager:status()
--- Method
--- Get the current status of the WindowManager
---
--- Parameters:
---  * None
---
--- Returns:
---  * A string describing the current status
function obj:status()
    return M.status()
end

return obj
