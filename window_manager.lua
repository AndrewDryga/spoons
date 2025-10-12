-- Window manager for Hammerspoon: tiling + deterministic fullscreen with minimal hops.
-- Compact debug logs; centralized timings via T; single cache in state.model.spaces.
---@diagnostic disable-next-line: undefined-global, lowercase-global
hs = hs or {}

local M = {}

--------------------------------------------------------------------------------
-- Timings
--------------------------------------------------------------------------------
local T = {
    -- Space hops
    HOP_TIMEOUT = 2.0,        -- seconds
    HOP_POLL_INTERVAL = 0.02, -- seconds
    HOP_SETTLE_DELAY = 0.2,   -- seconds

    -- Fullscreen creation polling
    FS_POLL_TIMEOUT = 2.0,      -- seconds
    FS_POLL_INTERVAL = 0.1,     -- seconds
    FULLSCREEN_SET_DELAY = 0.1, -- seconds to let focus settle before setFullScreen(true)

    -- App readiness
    APP_READY_POLL_INTERVAL = 0.2, -- seconds

    -- Exit fullscreen sequence
    EXIT_KEY_DELAY = 0.18,             -- seconds before keystroke fallback
    EXIT_POLL_TIMEOUT = 1.2,           -- seconds max to wait for exit
    EXIT_POLL_INTERVAL = 0.12,         -- seconds between exit checks
    POST_EXIT_PRECOLLECT_DELAY = 0.05, -- seconds before recollect windows
    POST_EXIT_CALLBACK_DELAY = 0.05,   -- seconds before calling back after recollect

    -- Tiling
    SECOND_TILING_PASS_DELAY = 0.18, -- seconds between initial and second tiling pass

    -- Launch throttling
    LAUNCH_THROTTLE_SEC = 2.0, -- seconds between quiet launches per bundle
}

--------------------------------------------------------------------------------
-- Module State
--------------------------------------------------------------------------------
local state = {
    config = nil,
    screen_watcher = nil,
    space_watcher = nil,
    active_hotkeys = {},
    current_screen_name = nil,
    debounce_timer = nil,
    launch_throttle = {},
    -- Unified model: spaces[spaceID] = { type = "user"|"fullscreen"|?, occupantBid = "bundle.id" }
    model = { spaces = {} },
    is_discovering_spaces = false,
    is_applying = false,
}

--------------------------------------------------------------------------------
-- Logging
--------------------------------------------------------------------------------
local function log(fmt, ...)
    if state.config and state.config.debug then
        print(string.format("[wm] " .. fmt, ...))
    end
end

local function warn(fmt, ...)
    print(string.format("[wm][WARN] " .. fmt, ...))
end

--------------------------------------------------------------------------------
-- Utilities
--------------------------------------------------------------------------------

-- Generic poll helper: runs checkFn periodically until it returns a truthy result or timeout is reached.
local function pollUntil(label, checkFn, opts, on_done)
    local interval = (opts and opts.interval) or T.FS_POLL_INTERVAL
    local timeout = (opts and opts.timeout) or T.FS_POLL_TIMEOUT
    local deadline = hs.timer.secondsSinceEpoch() + timeout
    local poller
    local function cleanup()
        if poller then
            poller:stop()
            poller = nil
        end
    end
    poller = hs.timer.new(interval, function()
        local ok, res = pcall(checkFn)
        if ok and res then
            if state.config and state.config.debug then
                print(string.format("[wm][pollUntil:%s] success", label or "?"))
            end
            cleanup()
            if on_done then on_done(res) end
            return
        end
        if hs.timer.secondsSinceEpoch() > deadline then
            if state.config and state.config.debug then
                print(string.format("[wm][pollUntil:%s][TIMEOUT]", label or "?"))
            end
            cleanup()
            if on_done then on_done(nil) end
        end
    end)
    poller:start()
end

local function to_array(val)
    if type(val) == "table" then return val end
    if val == nil then return {} end
    return { val }
end

local function get_app(bundle_id)
    if not bundle_id then return nil end
    return hs.application.get(bundle_id)
end

local function quiet_launch(bundle_id)
    local now = hs.timer.secondsSinceEpoch()
    if (now - (state.launch_throttle[bundle_id] or 0)) < T.LAUNCH_THROTTLE_SEC then return end
    state.launch_throttle[bundle_id] = now
    log("Quietly launching %s", bundle_id)
    hs.task.new("/usr/bin/open", nil, { "-gj", "-b", bundle_id }):start()
end

-- Launch only apps that are not already running (avoid launching just because they may be in an undiscovered fullscreen space).
local function ensure_apps_running(bundle_ids)
    local apps_to_wait_for = {}
    for _, bid in ipairs(bundle_ids) do
        local app = get_app(bid)
        if not (app and app:isRunning()) then
            quiet_launch(bid)
            apps_to_wait_for[bid] = true
        end
    end
    return apps_to_wait_for
end

-- Exit fullscreen for all windows of an app, then move them to the first (main) space of the current target screen.
local function exit_fullscreen_for_app(app, callback)
    if not app then
        if callback then callback(app) end
        return
    end
    local app_name = app:name() or "<unknown>"
    log("Attempting to exit fullscreen for '%s' (UI menu + direct flag + keystroke + polling).", app_name)

    -- 1. AppleScript menu attempt
    local script = string.format([[
        tell application "%s" to activate
        delay 0.12
        tell application "System Events" to tell process "%s"
            try
                tell menu bar 1
                    tell menu bar item "View"
                        tell menu 1
                            if exists menu item "Exit Full Screen" then
                                click menu item "Exit Full Screen"
                            end if
                        end tell
                    end tell
                end tell
            end try
        end tell
    ]], app_name, app_name)
    hs.osascript.applescript(script)

    -- 2. Direct flag attempt
    for _, win in ipairs(app:allWindows()) do
        if win:isFullScreen() then
            pcall(function() win:setFullScreen(false) end)
        end
    end

    -- 3. Keystroke fallback (only if still fullscreen after menu + direct flag)
    hs.timer.doAfter(T.EXIT_KEY_DELAY, function()
        local stillFS = false
        for _, win in ipairs(app:allWindows()) do
            if win:isFullScreen() then
                stillFS = true
                break
            end
        end
        if stillFS then
            pcall(function()
                hs.eventtap.keyStroke({ "cmd", "ctrl" }, "f", 0)
            end)
        else
            log("Skip keystroke fallback for '%s' (no fullscreen windows detected).", app_name)
        end
    end)

    -- 4. Poll for up to ~1.2s until no windows are fullscreen or timeout
    local deadline = hs.timer.secondsSinceEpoch() + T.EXIT_POLL_TIMEOUT
    local function poll()
        local anyFS = false
        for _, win in ipairs(app:allWindows()) do
            if win:isFullScreen() then
                anyFS = true
                break
            end
        end
        if anyFS and hs.timer.secondsSinceEpoch() < deadline then
            hs.timer.doAfter(T.EXIT_POLL_INTERVAL, poll)
            return
        end

        hs.timer.doAfter(T.POST_EXIT_PRECOLLECT_DELAY, function()
            log("Finished exit fullscreen sequence for '%s'. Recollecting windows.", app_name)
            -- Force enumeration to ensure Hammerspoon updates internal bookkeeping
            for _, _w in ipairs(app:allWindows()) do
                -- Touch frame() to encourage metadata refresh
                pcall(function() _w:frame() end)
            end
            -- Optional hook other phases can set to trigger immediate recollect
            if state._pending_recollect then pcall(state._pending_recollect) end
            -- Small extra delay before invoking original callback to allow space collapse to finish
            hs.timer.doAfter(T.POST_EXIT_CALLBACK_DELAY, function()
                if callback then callback(app) end
            end)
        end)
    end
    poll()
end

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

    return hs.geometry.rect(x, y, w, h)
end

local function first_space_id(screen)
    local spaces = hs.spaces.spacesForScreen(screen) or {}
    return spaces[1]
end

--------------------------------------------------------------------------------
-- Screen/Profile Selection
--------------------------------------------------------------------------------
local function choose_target_screen_name()
    local profiles = state.config.profiles or {}
    local available_screens = hs.screen.allScreens()

    -- Find the first available screen that has a profile defined.
    for _, screen in ipairs(available_screens) do
        local name = screen:name()
        if profiles[name] then
            state.current_screen = screen
            log("Selected screen '%s' as target profile.", name)
            return name
        end
    end

    -- Fallback: use main screen if available, even if profile key differs slightly by name
    local main = hs.screen.mainScreen()
    if main then
        local name = main:name()
        if profiles[name] then
            state.current_screen = main
            log("Selected main screen '%s' as target profile (fallback).", name)
            return name
        end
        -- Still store for later use to avoid nil target_screen
        state.current_screen = main
        log("No matching profile by name; storing main screen '%s' for later use.", name)
    end

    log("No suitable screen with a profile found.")
    return nil
end

local function rebind_hotkeys()
    for _, hk in ipairs(state.active_hotkeys) do hk:delete() end
    state.active_hotkeys = {}
    log("Cleared hotkeys.")

    if not state.current_screen_name then return end
    local profile = state.config.profiles[state.current_screen_name]
    if not (profile and profile.layouts) then return end

    for _, layout in ipairs(profile.layouts) do
        if layout.hotkey then
            local mods, key = layout.hotkey.mods, layout.hotkey.key
            local bound = hs.hotkey.bind(mods, key, function()
                log("Hotkey triggered for layout '%s'.", layout.name)
                M.apply_layout(layout)
            end)
            table.insert(state.active_hotkeys, bound)
            log("Bound hotkey %s-%s for layout '%s'.", table.concat(mods, "+"), key, layout.name)
        end
    end
end

-- Utility to hop to a space and wait for the hop to complete using a poller.
-- This is more reliable than using an event watcher or a fixed timer.
local function goto_space_and_wait(space_id, callback, timeout)
    timeout = timeout or T.HOP_TIMEOUT
    -- Fast-path: already on target space, avoid no-op hop and logs
    if hs.spaces.activeSpaceOnScreen() == space_id then
        if callback then hs.timer.doAfter(0, callback) end
        return
    end
    log("[Space Hop] Initiating safe hop to space %s.", tostring(space_id))
    pcall(function() hs.spaces.gotoSpace(space_id) end)
    pollUntil("goto_space", function()
        return hs.spaces.activeSpaceOnScreen() == space_id
    end, { interval = T.HOP_POLL_INTERVAL, timeout = timeout }, function(ok)
        if ok then
            log("[Space Hop] Successfully arrived at space %s.", tostring(space_id))
            hs.timer.doAfter(T.HOP_SETTLE_DELAY, function()
                if callback then callback() end
            end)
        else
            warn("[Space Hop][TIMEOUT] space %s", tostring(space_id))
            if callback then callback() end
        end
    end)
end



-- Polls until all windows of a given app have been moved to the main desktop space.
-- This is used to wait for the OS animation to finish after exiting fullscreen.
local function poll_for_window_settling(app, on_done)
    if not app then
        log("[Poll Settling] No app provided. Skipping.")
        return on_done()
    end
    local target_screen = hs.screen.find(state.current_screen_name)
    if not target_screen then
        log("[Poll Settling][WARN] No target screen found for app '%s'. Skipping.", app:name())
        return on_done()
    end
    local first_space = first_space_id(target_screen)
    if not first_space then
        log("[Poll Settling][WARN] No main desktop space found for app '%s'. Skipping.", app:name())
        return on_done()
    end

    local function begin()
        pollUntil("settle_windows", function()
            local wins = app:allWindows()
            if not wins or #wins == 0 then return false end
            for _, win in ipairs(wins) do
                local ok, spaces = pcall(hs.spaces.windowSpaces, win)
                if not (ok and spaces and #spaces == 1 and spaces[1] == first_space) then
                    return false
                end
            end
            return true
        end, { interval = T.FS_POLL_INTERVAL, timeout = T.FS_POLL_TIMEOUT }, function(ok)
            if ok then
                log("[Poll Settling] '%s' windows settled on %s.", app:name(), tostring(first_space))
            else
                warn("[Poll Settling][TIMEOUT] '%s'", app:name())
            end
            if on_done then on_done() end
        end)
    end

    if hs.spaces.activeSpaceOnScreen() == first_space then
        begin()
    else
        goto_space_and_wait(first_space, begin)
    end
end

-- Polls until a window has successfully entered a new fullscreen space.
local function poll_for_fullscreen_creation(win, on_done)
    if not win then
        log("[Poll Fullscreen] No window provided. Skipping.")
        return on_done(nil)
    end
    log("[Poll Fullscreen] Waiting for window '%s' to enter fullscreen...", tostring(win:title()))
    pollUntil("fullscreen_create", function()
        local ok, spaces = pcall(hs.spaces.windowSpaces, win)
        return ok and spaces and #spaces == 1 and hs.spaces.spaceType(spaces[1]) == "fullscreen" and spaces[1]
    end, { interval = T.FS_POLL_INTERVAL, timeout = T.FS_POLL_TIMEOUT }, function(sid)
        if sid then
            log("[Poll Fullscreen] Window '%s' is now in fullscreen space %s.", tostring(win:title()), tostring(sid))
        else
            warn("[Poll Fullscreen][TIMEOUT] '%s'", tostring(win:title()))
        end
        return on_done(sid)
    end)
end



-- Polls until all launched apps are running; no fixed timeout.
local function poll_for_apps_ready(apps_to_wait_for, on_done)
    if not apps_to_wait_for or next(apps_to_wait_for) == nil then
        return on_done()
    end
    pollUntil("apps_ready", function()
        for bid, _ in pairs(apps_to_wait_for) do
            local app = get_app(bid)
            if not (app and app:isRunning()) then
                return false
            end
        end
        return true
    end, { interval = T.APP_READY_POLL_INTERVAL, timeout = T.FS_POLL_TIMEOUT }, function(ok)
        if not ok then warn("[Apps Ready][TIMEOUT]") end
        return on_done()
    end)
end

-- Poll until an app has at least one window; no fixed timeout.
-- Accepts bundle id or app object. Calls on_done() when ready.
local function poll_for_app_windows(bid_or_app, on_done)
    pollUntil("app_windows", function()
        local app = type(bid_or_app) == "string" and get_app(bid_or_app) or bid_or_app
        if app and app:isRunning() then
            local wins = app:allWindows()
            if wins and #wins > 0 then
                return app
            end
        end
        return false
    end, { interval = T.APP_READY_POLL_INTERVAL, timeout = T.FS_POLL_TIMEOUT }, function(app)
        return on_done(app)
    end)
end

function handle_screen_change()
    log("Screen configuration changed.")
    local new_screen_name = choose_target_screen_name()
    if new_screen_name ~= state.current_screen_name then
        log("Active screen profile changed: '%s' -> '%s'", state.current_screen_name or "none", new_screen_name or "none")
        state.current_screen_name = new_screen_name
        rebind_hotkeys()
        if state.current_screen_name then
            local profile = state.config.profiles[state.current_screen_name]
            if profile and profile.layouts and #profile.layouts > 0 then
                log("Auto-applying default layout '%s' for screen '%s'.",
                    profile.layouts[1].name, state.current_screen_name)
                hs.timer.doAfter(0.1, function()
                    M.apply_layout(profile.layouts[1])
                end)
            end
        end
    end
end

local function schedule_screen_change_handler()
    if state.debounce_timer then state.debounce_timer:stop() end
    state.debounce_timer = hs.timer.doAfter(1.0, handle_screen_change)
end

--------------------------------------------------------------------------------
-- Space / Cache
--------------------------------------------------------------------------------

-- Update cache for active space: map active spaceID to the bundleID of the frontmost window's app
local function update_space_cache()
    log("[Cache Update] Watcher triggered.")
    if state.is_discovering_spaces then return end
    local front = hs.window.frontmostWindow()
    if not front then return end
    local app = front:application()
    if not app then return end
    local bid = app:bundleID()
    local okSpace, space_id = pcall(hs.spaces.activeSpaceOnScreen)
    if not okSpace or not space_id then return end

    local typOk, typ = pcall(hs.spaces.spaceType, space_id)
    local prev = state.model.spaces[space_id] or {}
    if prev.occupantBid ~= bid or prev.type ~= (typOk and typ or nil) then
        log("[Cache Update] Active window is '%s' (%s) on space %s", app:name() or "N/A", tostring(bid),
            tostring(space_id))
        state.model.spaces[space_id] = { type = (typOk and typ or nil), occupantBid = bid }
        log("Cache: space %s -> %s", tostring(space_id), tostring(bid))
    end
end

--------------------------------------------------------------------------------
-- Layout Parsing
--------------------------------------------------------------------------------

-- Parse layout definition into tiling and fullscreen sets.
-- layout.space_layouts example:
-- [1] = { ["Top"] = { bidA }, ["Bottom"] = { bidB, bidC } }
-- [2] = { bidD }
-- [3] = { bidE }
local function parse_layout(layout, profile)
    local result = {
        tiling = {},          -- tileName -> { bundleIDs }
        fullscreenOrder = {}, -- ordered list of bundleIDs (space index ascending >1)
        tilingSet = {},       -- set of bundleIDs in tiles
        allBundles = {},      -- set of all bundleIDs mentioned
        focusApp = layout.focusApp,
    }

    local tiles_def = (profile and profile.tiles) or {}

    if not layout.space_layouts then
        return result
    end

    -- Handle tiling layout (space 1) first
    if layout.space_layouts[1] and type(layout.space_layouts[1]) == "table" then
        local spec = layout.space_layouts[1]
        local treat_as_tile_map = false
        for k, _ in pairs(spec) do
            if type(k) == "string" and tiles_def[k] then
                treat_as_tile_map = true
                break
            end
        end

        if treat_as_tile_map then
            for tileName, bundleList in pairs(spec) do
                if tiles_def[tileName] then
                    local arr = {}
                    for _, bid in ipairs(to_array(bundleList)) do
                        arr[#arr + 1] = bid
                        result.tilingSet[bid] = true
                        result.allBundles[bid] = true
                    end
                    result.tiling[tileName] = arr
                else
                    warn("Tile '%s' referenced in layout but not defined in profile '%s'.", tileName,
                        state.current_screen_name or "unknown")
                end
            end
        else
            warn("Space 1 specified as plain array; expected tile map. Ignoring this entry.")
        end
    end

    -- Collect and sort fullscreen space keys to ensure correct order
    local fs_keys = {}
    for spaceIndex, _ in pairs(layout.space_layouts) do
        if type(spaceIndex) == "number" and spaceIndex > 1 then
            table.insert(fs_keys, spaceIndex)
        end
    end
    table.sort(fs_keys)

    -- Process fullscreen apps in their defined order
    for _, spaceIndex in ipairs(fs_keys) do
        local spec = layout.space_layouts[spaceIndex]
        if type(spec) == "table" then
            for _, bid in ipairs(spec) do
                result.fullscreenOrder[#result.fullscreenOrder + 1] = bid
                result.allBundles[bid] = true
            end
        end
    end







    return result
end

--------------------------------------------------------------------------------
-- App / Window Collection
--------------------------------------------------------------------------------

local function collect_app_windows(bundleSet)
    local mapping = {}
    for bid, _ in pairs(bundleSet) do
        local app = get_app(bid)
        local windows = {}
        if app and app:isRunning() then
            -- Collect all windows; filtering is done by consumers (apply_tiling, apply_fullscreen)
            windows = app:allWindows()
        end
        mapping[bid] = {
            app = app,
            windows = windows,
        }
    end
    return mapping
end

-- Expand a base fullscreen bundle order into a round-robin sequence by available window counts.
-- This preserves the primary bundle order while interleaving extra windows of apps with more than one window.
local function expand_fullscreen_order_block(baseOrder, appWindows)
    if not baseOrder or #baseOrder == 0 then return {} end
    -- Count usable windows for each app (standard and not minimized)
    local counts = {}
    local perAppWindows = {}
    for _, bid in ipairs(baseOrder) do
        local entry = appWindows and appWindows[bid]
        local list = {}
        if entry and entry.windows then
            for _, w in ipairs(entry.windows) do
                if w:isStandard() and not w:isMinimized() then
                    list[#list + 1] = w
                end
            end
        end
        perAppWindows[bid] = list
        counts[bid] = #list
    end

    -- Compute the max number of windows across selected apps
    local maxCount = 0
    for _, bid in ipairs(baseOrder) do
        if counts[bid] > maxCount then maxCount = counts[bid] end
    end
    if maxCount == 0 then
        -- No windows right now; return the base order as-is to let the poller pick them up
        local copy = {}
        for i = 1, #baseOrder do copy[i] = baseOrder[i] end
        return copy
    end

    -- Block-per-app expansion preserving base order
    local expanded = {}
    for _, bid in ipairs(baseOrder) do
        local n = counts[bid] or 0
        for i = 1, n do
            expanded[#expanded + 1] = bid
        end
    end
    if #expanded == 0 then
        local copy = {}
        for i = 1, #baseOrder do copy[i] = baseOrder[i] end
        return copy
    end
    return expanded
end

-- Detect native fullscreen more robustly: some apps report window:isFullScreen()==false
-- while living alone in a fullscreen space. We treat a window as effectively fullscreen if:
--  * win:isFullScreen() is true
--  * OR it occupies exactly one space and that space type is 'fullscreen'
local function _is_effectively_fullscreen(win)
    if not win then return false end
    local app_name = win:application() and win:application():name() or "N/A"
    local win_title = win:title() or "N/A"

    local is_fs_flag = win:isFullScreen()
    if is_fs_flag then
        log("[FS Check] Window '%s' of '%s': isFullScreen() is TRUE.", win_title, app_name)
        return true
    end

    local ok, spaces = pcall(hs.spaces.windowSpaces, win)
    if ok and spaces then
        if #spaces == 1 then
            local space_type = hs.spaces.spaceType(spaces[1])
            if space_type == "fullscreen" then
                log("[FS Check] Window '%s' of '%s': is on a single fullscreen space (%s). Treating as fullscreen.",
                    win_title, app_name, tostring(spaces[1]))
                return true
            else
                log("[FS Check] Window '%s' of '%s': is on a single non-fullscreen space (%s, type=%s).", win_title,
                    app_name, tostring(spaces[1]), tostring(space_type))
            end
        else
            log("[FS Check] Window '%s' of '%s': is on %d spaces. Not considered fullscreen.", win_title, app_name,
                #spaces)
        end
    else
        log("[FS Check] Window '%s' of '%s': could not get windowSpaces.", win_title, app_name)
    end

    return false
end



--------------------------------------------------------------------------------
-- Pipeline Helpers
--------------------------------------------------------------------------------



-- Move and tile all windows for each tile assignment.
local function apply_tiling(tilingMap, appWindows, target_screen)
    if not target_screen then return 0 end
    local first_space = first_space_id(target_screen)
    if not first_space then
        warn("No first space found for screen '%s'; cannot tile.", target_screen:name() or "")
        return 0
    end

    local moves = 0

    local tiles_def = state.config.profiles[state.current_screen_name].tiles or {}

    local used_bundle_once = {} -- to warn if same app appears in multiple tiles
    for tileName, bundleIDs in pairs(tilingMap) do
        local tile_spec = tiles_def[tileName]
        if not tile_spec then
            warn("Tile '%s' missing spec; skipping.", tileName)
        else
            local frame = compute_tile_frame(tile_spec, target_screen)
            for _, bid in ipairs(bundleIDs) do
                if used_bundle_once[bid] and used_bundle_once[bid] ~= tileName then
                    warn("Bundle '%s' already tiled in '%s'; duplicate in '%s' ignored (stacked anyway).",
                        bid, used_bundle_once[bid], tileName)
                else
                    used_bundle_once[bid] = tileName
                end
                local entry = appWindows[bid]
                local windows_to_tile = {}
                if entry and entry.app and entry.app:isRunning() then
                    for _, win in ipairs(entry.windows or {}) do
                        if win:isStandard() and not win:isMinimized() and not _is_effectively_fullscreen(win) then
                            table.insert(windows_to_tile, win)
                        end
                    end
                end

                if #windows_to_tile > 0 then
                    for _, win in ipairs(windows_to_tile) do
                        -- Move to target screen if different
                        if win:screen() ~= target_screen then
                            pcall(function() win:moveToScreen(target_screen, false, true) end)
                        end
                        -- Move to first space
                        pcall(function() hs.spaces.moveWindowToSpace(win, first_space) end)
                        -- Apply frame
                        pcall(function() win:setFrame(frame) end)
                        moves = moves + 1
                    end
                elseif entry and entry.app and entry.app:isRunning() and #(entry.windows or {}) == 0 then
                    -- App is running but has no windows. This is a valid warning.
                    warn("No windows found to tile for bundle '%s'.", bid)
                end
                -- If windows exist but none are tileable (e.g., all fullscreen), the warning is now correctly suppressed.
            end
        end
    end
    return moves
end

-- Helper to find an existing, unused fullscreen window for an app
local function find_unused_fullscreen_window(win_list, used_windows_map)
    for _, w in ipairs(win_list or {}) do
        if not used_windows_map[w:id()] and _is_effectively_fullscreen(w) then
            local ok, spaces = pcall(hs.spaces.windowSpaces, w)
            local sid = ok and spaces and spaces[1] or nil
            if sid then return w, sid end
        end
    end
    return nil, nil
end

-- Enter fullscreen for each bundleID (one window per bundle).
local function apply_fullscreen(fullscreenOrder, appWindows, target_screen, on_done)
    state.is_discovering_spaces = true
    local idx = 1
    local new_space_ids_in_order = {}
    local used_windows = {} -- Track window IDs that have been put into fullscreen
    local first_space = first_space_id(target_screen)
    -- Short-circuit: nothing to fullscreen
    if not fullscreenOrder or #fullscreenOrder == 0 then
        state.is_discovering_spaces = false
        if on_done then on_done({}) end
        return
    end
    log("[FS Plan] Order: %s", table.concat(fullscreenOrder, ", "))

    local function next_fullscreen(new_sid)
        if new_sid then
            table.insert(new_space_ids_in_order, new_sid)
        end

        if idx > #fullscreenOrder then
            state.is_discovering_spaces = false
            if on_done then on_done(new_space_ids_in_order) end
            return
        end

        local bid = fullscreenOrder[idx]
        idx = idx + 1

        -- Skip pre-hop: we'll hop to the window's own space only if needed just before fullscreening

        -- refresh and union app/windows live for this iteration to avoid losing windows seen earlier
        local entry = appWindows[bid] or { app = nil, windows = {} }
        if not (entry.app and entry.app:isRunning()) then
            entry.app = entry.app or get_app(bid)
        end

        local snapshot = {}
        if entry.app and entry.app:isRunning() then
            snapshot = entry.app:allWindows() or {}
        end

        -- Build a map of existing windows by id to preserve previously seen ones
        local existing_by_id = {}
        for _, w in ipairs(entry.windows or {}) do
            local ok, id = pcall(function() return w:id() end)
            if ok and id then
                existing_by_id[id] = w
            end
        end

        -- Union new snapshot into the existing set
        for _, w in ipairs(snapshot) do
            local ok, id = pcall(function() return w:id() end)
            if ok and id then
                existing_by_id[id] = w
            end
        end

        -- Rebuild an ordered list: prefer current snapshot order, then any remaining from previous
        local merged = {}
        local seen = {}
        for _, w in ipairs(snapshot) do
            local ok, id = pcall(function() return w:id() end)
            if ok and id and not seen[id] then
                merged[#merged + 1] = w
                seen[id] = true
            end
        end
        for id, w in pairs(existing_by_id) do
            if not seen[id] then
                merged[#merged + 1] = w
            end
        end

        entry.windows = merged
        appWindows[bid] = entry

        if entry and entry.app then
            local win_descriptions = {}
            for _, w in ipairs(entry.windows or {}) do
                local ok, spaces = pcall(hs.spaces.windowSpaces, w)
                local sid = ok and spaces and spaces[1] or nil
                log("[FS] Candidate window for '%s': id=%s title='%s' std=%s min=%s fs=%s space=%s screen='%s'",
                    bid, tostring(w:id()), tostring(w:title()),
                    tostring(w:isStandard()),
                    tostring(w:isMinimized()),
                    tostring(_is_effectively_fullscreen(w)),
                    tostring(sid),
                    w:screen() and w:screen():name() or "N/A")
            end
        end

        if not entry or not entry.app then
            log("[FS] App '%s' not running yet; polling until first window appears.", bid)
            return poll_for_app_windows(bid, function()
                -- refresh entry and retry this app immediately
                local a = get_app(bid)
                appWindows[bid] = { app = a, windows = (a and a:allWindows()) or {} }
                -- schedule this app again at the end of the queue
                table.insert(fullscreenOrder, bid)
                next_fullscreen(nil)
            end)
        end

        -- If the app is running but has zero windows, try a one-time hop to main space to refresh enumeration
        if not entry.windows or #entry.windows == 0 then
            log("[FS] No candidate windows for '%s'; skipping.", bid)
            return next_fullscreen(nil)
        end

        -- Phase 1: Adopt an existing, unused fullscreen window if available
        local adopted_win, adopted_sid = find_unused_fullscreen_window(entry.windows, used_windows)
        if adopted_win then
            log("[FS] Adopting existing fullscreen window for '%s': id=%s on space %s", bid,
                tostring(adopted_win:id()), tostring(adopted_sid))
            used_windows[adopted_win:id()] = true
            -- Check for more windows of the same app to enqueue
            do
                local has_more = false
                for _, w in ipairs(entry.windows) do
                    if not used_windows[w:id()] and w:isStandard() and not w:isMinimized() then
                        has_more = true
                        break
                    end
                end
                if has_more then table.insert(fullscreenOrder, bid) end
            end
            return next_fullscreen(adopted_sid)
        end

        -- Phase 2: If no window adopted, find a standard window to make fullscreen
        local win = nil
        local active_sid = hs.spaces.activeSpaceOnScreen()
        -- First pass: prefer windows on active or main space
        for _, w in ipairs(entry.windows) do
            if not used_windows[w:id()] and w:isStandard() and not w:isMinimized() and not _is_effectively_fullscreen(w) then
                local okSp, sp = pcall(hs.spaces.windowSpaces, w)
                local sid = okSp and sp and sp[1] or nil
                if sid == active_sid or (first_space and sid == first_space) then
                    win = w
                    break
                end
            end
        end
        -- Fallback: any remaining standard window
        if not win then
            for _, w in ipairs(entry.windows) do
                if not used_windows[w:id()] and w:isStandard() and not w:isMinimized() and not _is_effectively_fullscreen(w) then
                    win = w
                    break
                end
            end
        end

        if not win then
            warn("No more candidate windows for bundle '%s'. Skipping.", bid)
            return next_fullscreen(nil)
        end
        log("[FS] Selected window for '%s': id=%s title='%s'", bid, tostring(win:id()), tostring(win:title()))

        -- Mark this window as used for this layout application
        used_windows[win:id()] = true
        -- If there are more unused windows for this app, enqueue it again
        do
            local has_more = false
            for _, w in ipairs(entry.windows) do
                if not used_windows[w:id()] and w:isStandard() and not w:isMinimized() then
                    has_more = true
                    break
                end
            end
            if has_more then
                table.insert(fullscreenOrder, bid)
                log("[FS] Enqueued additional window of '%s' for fullscreen (remaining).", bid)
            end
        end

        if target_screen and win:screen() ~= target_screen then
            pcall(function() win:moveToScreen(target_screen, false, true) end)
        end

        if _is_effectively_fullscreen(win) then
            local _, spaces = pcall(hs.spaces.windowSpaces, win)
            local sid = spaces and spaces[1] or nil
            log("Window for bundle '%s' already effectively fullscreen (id=%s) on space %s. Skipping.", bid,
                tostring(win:id()), tostring(sid))
            return next_fullscreen(sid)
        end

        -- This function contains the logic to actually make the window fullscreen.
        local function do_fullscreen()
            if win:isMinimized() then pcall(function() win:unminimize() end) end
            pcall(function() win:focus() end)
            hs.timer.doAfter(T.FULLSCREEN_SET_DELAY, function()
                log("[FS] setFullScreen(true) for '%s' id=%s", bid, tostring(win:id()))
                pcall(function() win:setFullScreen(true) end)
                poll_for_fullscreen_creation(win, next_fullscreen)
            end)
        end

        -- Minimize hops: move window to current active space (if needed) and fullscreen it
        local active_sid = hs.spaces.activeSpaceOnScreen()
        local ok, win_spaces = pcall(hs.spaces.windowSpaces, win)
        local win_space = (ok and win_spaces and win_spaces[1]) and win_spaces[1] or nil
        if win_space and win_space ~= active_sid then
            local _ = pcall(function() hs.spaces.moveWindowToSpace(win, active_sid) end)
            -- Verify move; if still not on active space, fall back to a single hop to window's space
            local ok2, sp2 = pcall(hs.spaces.windowSpaces, win)
            local sid2 = ok2 and sp2 and sp2[1] or nil
            if not sid2 or sid2 ~= active_sid then
                return goto_space_and_wait(win_space, do_fullscreen)
            end
        end
        do_fullscreen()
    end

    next_fullscreen()
end

--------------------------------------------------------------------------------
-- Core Layout Application
--------------------------------------------------------------------------------
function M.apply_layout(layout)
    if not layout then
        log("apply_layout: nil layout provided.")
        return
    end
    if state.is_applying then
        log("apply_layout: already applying; deferring '%s'.", layout.name or "<unnamed>")
        state._deferred_layout = layout
        return
    end
    if not state.current_screen_name then
        log("apply_layout: no active screen profile selected.")
        return
    end

    local profile = state.config.profiles[state.current_screen_name]
    if not profile then
        log("apply_layout: profile for screen '%s' not found.", state.current_screen_name)
        return
    end

    state.is_applying = true
    log("Applying layout '%s' for screen '%s'.", layout.name or "<unnamed>", state.current_screen_name)

    local original_animation = hs.window.animationDuration
    hs.window.animationDuration = 0

    local ok, err = pcall(function()
        -- 1. Parse layout
        local parsed = parse_layout(layout, profile)

        -- 2. Ensure apps running (only those not currently running)
        local all_bundle_list = {}
        for bid, _ in pairs(parsed.allBundles) do table.insert(all_bundle_list, bid) end
        local apps_to_wait_for = ensure_apps_running(all_bundle_list)

        poll_for_apps_ready(apps_to_wait_for, function()
            -- 3. Collect app windows (initial snapshot)
            local appWindows = collect_app_windows(parsed.allBundles)

            -- Resolve target screen for this profile and guard if missing
            local target_screen = state.current_screen or hs.screen.find(state.current_screen_name) or
                hs.screen.mainScreen()
            if not target_screen then
                warn("Target screen not found; aborting layout (no screen object available).")
                state.is_applying = false
                hs.window.animationDuration = original_animation
                return
            end
            -- Persist the resolved screen object for subsequent operations
            state.current_screen = target_screen

            local original_space = hs.spaces.activeSpaceOnScreen()

            -- Phase: Smart Scan + Normalize in a single pass
            -- Runs if the layout has fullscreen spaces OR there are any existing fullscreen spaces on the target screen.
            -- For each fullscreen space, we hop once: update cache and, if occupant is in tiling set, exit fullscreen and wait for settling.
            local function scan_and_normalize(on_done)
                local screen_spaces = hs.spaces.spacesForScreen(target_screen) or {}
                local fullscreen_spaces = {}
                local all_known = true
                for _, sid in ipairs(screen_spaces) do
                    if hs.spaces.spaceType(sid) == "fullscreen" then
                        table.insert(fullscreen_spaces, sid)
                        if not state.model.spaces[sid] then
                            all_known = false
                        end
                    end
                end

                if all_known and #fullscreen_spaces > 0 then
                    log("[Scan+Normalize] Skipping (all %d fullscreen spaces are cached).", #fullscreen_spaces)
                    return on_done()
                end

                local should_run = (#fullscreen_spaces > 0) or (#parsed.fullscreenOrder > 0)
                if not should_run then
                    state.is_discovering_spaces = false
                    return on_done()
                end

                state.is_discovering_spaces = true
                log("[Scan+Normalize] Scanning %d fullscreen space(s).", #fullscreen_spaces)
                local i = 1
                local function step()
                    if i > #fullscreen_spaces then
                        -- After processing, return to the original space if we're not already there.
                        local finish = function()
                            state.is_discovering_spaces = false
                            log("[Scan+Normalize] Complete.")
                            return on_done()
                        end
                        if hs.spaces.activeSpaceOnScreen() == original_space then
                            return finish()
                        else
                            return goto_space_and_wait(original_space, finish)
                        end
                    end

                    local sid = fullscreen_spaces[i]
                    i = i + 1


                    -- Skip stale space IDs that no longer exist (avoid hop timeouts)
                    do
                        local exists = false
                        local list = hs.spaces.spacesForScreen(target_screen) or {}
                        for _, x in ipairs(list) do
                            if x == sid then
                                exists = true; break
                            end
                        end
                        if not exists then
                            warn("[Scan+Normalize] Stale space %s; skipping.", tostring(sid))
                            return step()
                        end
                    end

                    -- Hop to the space once: update cache and normalize if needed.
                    goto_space_and_wait(sid, function()
                        local front = hs.window.frontmostWindow()
                        if front and front:application() then
                            local app = front:application()
                            local bid = app:bundleID()
                            if bid then
                                state.model.spaces[sid] = { type = "fullscreen", occupantBid = bid }
                                log("Cache (scan): space %s -> %s", tostring(sid), tostring(bid))
                            end
                            if bid and parsed.tilingSet[bid] then
                                log("[Scan+Normalize] Space %s occupant '%s' is tiling; exiting fullscreen.",
                                    tostring(sid), tostring(bid))
                                exit_fullscreen_for_app(app, function(exited_app)
                                    poll_for_window_settling(exited_app, step)
                                end)
                                return
                            end
                        else
                            log("[Scan+Normalize] No frontmost window on space %s.", tostring(sid))
                        end
                        step()
                    end)
                end
                step()
            end



            -- Phase 3: Final Placement
            local function final_placement()
                log("Normalization complete. Proceeding to final placement.")
                appWindows = collect_app_windows(parsed.allBundles)
                local moved1 = apply_tiling(parsed.tiling, appWindows, target_screen)

                local function proceed_to_fullscreen()
                    appWindows = collect_app_windows(parsed.allBundles)
                    local fsOrder = expand_fullscreen_order_block(parsed.fullscreenOrder, appWindows)
                    -- Deterministic ordering: create from main space and reverse so final order matches layout left-to-right
                    local fsOrderRev = {}
                    for i = #fsOrder, 1, -1 do fsOrderRev[#fsOrderRev + 1] = fsOrder[i] end
                    apply_fullscreen(fsOrderRev, appWindows, target_screen, function(new_space_ids)
                        -- Order enforcement disabled: skip space re-order for faster, simpler flow.
                        do
                            if #new_space_ids > 0 then
                                log("[Order Enforce] Skipping spaces re-order (disabled).")
                            end
                        end

                        -- 7. Focus app if requested
                        if parsed.focusApp then
                            local focusEntry = appWindows[parsed.focusApp]
                            if focusEntry and focusEntry.app then
                                local frontWin = focusEntry.app:mainWindow() or focusEntry.app:focusedWindow()
                                if frontWin then pcall(function() frontWin:focus() end) end
                            end
                        end
                        log("Layout '%s' application complete.", layout.name or "<unnamed>")
                        state.is_applying = false
                        hs.window.animationDuration = original_animation
                        local deferred = state._deferred_layout
                        state._deferred_layout = nil
                        if deferred and deferred ~= layout then
                            hs.timer.doAfter(0.01, function() M.apply_layout(deferred) end)
                        end
                    end)
                end

                if moved1 > 0 then
                    hs.timer.doAfter(T.SECOND_TILING_PASS_DELAY, function()
                        appWindows = collect_app_windows(parsed.allBundles)
                        apply_tiling(parsed.tiling, appWindows, target_screen)
                        proceed_to_fullscreen()
                    end)
                else
                    proceed_to_fullscreen()
                end
            end

            -- Chain the operations: Scan+Normalize -> Place
            scan_and_normalize(final_placement)
        end)
    end)

    if not ok then
        warn("Error during layout apply: %s", tostring(err))
        state.is_discovering_spaces = false
        state.is_applying = false
        hs.window.animationDuration = original_animation
    end
end

--------------------------------------------------------------------------------
-- Public API: setup / teardown
--------------------------------------------------------------------------------

function M.setup(config)
    log("Setting up window manager...")
    -- Idempotent setup: clear previous watchers/hotkeys if any
    if state.screen_watcher or state.space_watcher or state.debounce_timer or (#state.active_hotkeys > 0) then
        M.teardown()
    end
    state.config = config
    hs.window.animationDuration = 0

    state.screen_watcher = hs.screen.watcher.new(schedule_screen_change_handler)
    state.screen_watcher:start()

    state.space_watcher = hs.spaces.watcher.new(update_space_cache)
    state.space_watcher:start()

    handle_screen_change()
end

function M.teardown()
    log("Tearing down window manager...")
    if state.screen_watcher then
        state.screen_watcher:stop()
        state.screen_watcher = nil
    end
    if state.space_watcher then
        state.space_watcher:stop()
        state.space_watcher = nil
    end
    if state.debounce_timer then
        state.debounce_timer:stop()
        state.debounce_timer = nil
    end
    for _, hk in ipairs(state.active_hotkeys) do hk:delete() end
    state.active_hotkeys = {}
    state.is_applying = false
end

function M.status()
    local hotkey_count = #state.active_hotkeys
    local cache_lines = {}
    for sid, meta in pairs(state.model.spaces) do
        table.insert(cache_lines,
            string.format("%s -> %s (type=%s)", tostring(sid), tostring(meta.occupantBid), tostring(meta.type)))
    end
    table.sort(cache_lines)
    local report = {}
    table.insert(report, string.format("current_screen_name: %s", tostring(state.current_screen_name)))
    table.insert(report, string.format("is_applying: %s", tostring(state.is_applying)))
    table.insert(report, string.format("active_hotkeys: %d", hotkey_count))
    table.insert(report, string.format("screen_watcher_active: %s", tostring(state.screen_watcher ~= nil)))
    table.insert(report, string.format("space_watcher_active: %s", tostring(state.space_watcher ~= nil)))
    table.insert(report, "space_app_cache:")
    for _, line in ipairs(cache_lines) do table.insert(report, "  " .. line) end
    local text = table.concat(report, "\n")
    print("[wm][STATUS]\n" .. text)
    return text
end

return M
