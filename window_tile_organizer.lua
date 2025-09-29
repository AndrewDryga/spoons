-- window_tile_organizer.lua
-- Arrange multiple app windows into named tiles with a single hotkey (preset).
-- Schema: layouts use space_layouts; focusApp is optional; no Space switching.
-- Robust screen handling, non-blocking placement and retries. Supports percentage-based tile sizing
-- via wPct/hPct.
--
-- API:
--   local organizer = require("window_tile_organizer")
--   organizer.setup({
--     tiles = {
--       ["Top"]          = { w = 1714, h = 1520, anchor = "top-center" },   -- anchor optional, defaults based on key
--       ["Top Left"]     = { w = 1059, h = 938,  anchor = "top-left" },
--       ["Bottom Left"]  = { w = 1059, h = 580,  anchor = "bottom-left" },
--       ["Top Right"]    = { w = 1059, h = 938,  anchor = "top-right" },
--       ["Bottom Right"] = { w = 1059, h = 580,  anchor = "bottom-right" },
--       ["Bottom"]       = { w = 1714, h = 1520, anchor = "bottom-center" }, -- supports bottom-center
--     },
--     layouts = {
--       {
--         name = "Editor",
--         hotkey = { mods = {"cmd"}, key = "1" },
--         targetScreen   = "focused",          -- "focused" | "main" | "byUUID:<uuid>" | "byName:<name>"
--         focusApp = "com.google.Chrome",      -- optional: focus this app if a window exists on the current space (no switching)
--         space_layouts  = {
--           [1]       = { ["Top"] = { "dev.zed.Zed" }, ... },   -- numeric space index
--           current   = { ["Top"] = { "dev.zed.Zed" }, ... },   -- the current space index at apply time
--         },
--       },
--     },
--     options = {
--       debug = false,
--       autoLaunch = false,                 -- default false; when true, launch missing apps (may change focus by macOS)
--       retryAttempts = 16,                 -- non-blocking retries per tile if window not ready yet
--       retryInterval = 0.20,               -- seconds between retries
--       scaleToFitIfTooLarge = true,
--       padding = 0,                        -- global padding applied to tiles
--     },
--   })
--   organizer.applyLayout("Editor")
--   organizer.teardown()
--
-- Notes:
-- - No Space switching is performed (no animations). Windows are moved to target Spaces in background.
--   Frames are only applied on the current Space. For other Spaces, frames are deferred until that Space
--   becomes current (finalized via a small watcher).
-- - "Top" defaults to "top-center". "Bottom" defaults to "bottom-center". Other keys default by name.

---@diagnostic disable-next-line: undefined-global
local hs = hs

local M = {}

-- Internal state
local state = {
    configured = false,
    tiles = {},
    layouts = {},
    hotkeys = {},
    options = {},
    -- Deferred placements when target space isn't current: { [spaceId] = { { win, frame }, ... } }
    pendingFramesBySpace = {},
    spaceWatcher = nil,
    _warnedNoAddSpace = false,
}

-- Defaults
local DEFAULT_OPTIONS = {
    debug = false,
    autoLaunch = false,
    retryAttempts = 16,
    retryInterval = 0.20,
    scaleToFitIfTooLarge = true,
    padding = 0,
}

-- Logging
local function logEnabled() return state.options and state.options.debug end
local function log(...) if logEnabled() then print("[tile_organizer]", ...) end end

-- Safe screen helpers
local function firstScreen()
    local all = hs.screen.allScreens()
    return (all and all[1]) or nil
end

local function safeMainScreen()
    return hs.screen.mainScreen() or firstScreen()
end

local function focusedScreen()
    local w = hs.window.frontmostWindow()
    return (w and w:screen()) or safeMainScreen()
end

local function screenByTarget(target)
    if target == nil or target == "focused" then
        return focusedScreen()
    end
    if target == "main" then
        return safeMainScreen()
    end
    if type(target) == "string" then
        local byUUID = target:match("^byUUID:(.+)$")
        if byUUID then
            for _, s in ipairs(hs.screen.allScreens()) do
                if s:getUUID() == byUUID then return s end
            end
            return safeMainScreen()
        end
        local byName = target:match("^byName:(.+)$")
        if byName then
            for _, s in ipairs(hs.screen.allScreens()) do
                if (s:name() or "") == byName then return s end
            end
            return safeMainScreen()
        end
    end
    return safeMainScreen()
end

-- Spaces helpers
local function allSpacesForScreen(scr)
    local ok, all = pcall(hs.spaces.allSpaces)
    if not ok then
        log("spaces: allSpaces() unavailable; deferring")
        return nil
    end
    return (all and scr and scr.getUUID and all[scr:getUUID()]) or nil
end

local function currentSpaceId()
    local ok, sid = pcall(hs.spaces.focusedSpace)
    if not ok then
        log("spaces: focusedSpace() unavailable; using nil")
    end
    return ok and sid or nil
end

local function spaceIdForIndexOnScreen(scr, idx)
    local list = allSpacesForScreen(scr)
    if not list or #list == 0 then return nil end
    if type(idx) ~= "number" then return nil end
    if idx < 1 then idx = 1 end
    if idx > #list then return nil end
    return list[idx]
end

local function indexOfSpaceOnScreen(scr, sid)
    local list = allSpacesForScreen(scr)
    if not (list and sid) then return nil end
    for i, s in ipairs(list) do if s == sid then return i end end
    return nil
end

-- Geometry helpers
local function clamp(v, lo, hi) if v < lo then return lo elseif v > hi then return hi else return v end end

local function visibleFrameOfScreen(scr)
    local s = scr or safeMainScreen()
    if s and s.frame then
        return s:frame()
    elseif s and s.fullFrame then
        return s:fullFrame()
    else
        return { x = 0, y = 0, w = 1440, h = 900 }
    end
end

local function normalizeAnchor(tileName, cfg)
    if cfg and cfg.anchor then return cfg.anchor end
    local lower = (tileName or ""):lower()
    if lower == "top" then return "top-center" end
    if lower == "bottom" then return "bottom-center" end
    if lower == "center" then return "center" end
    if lower == "top left" then return "top-left" end
    if lower == "bottom left" then return "bottom-left" end
    if lower == "top right" then return "top-right" end
    if lower == "bottom right" then return "bottom-right" end
    -- Fallback: left-top
    return "top-left"
end

local function rectWithinVisibleFrame(rect, vf)
    local r = { x = rect.x, y = rect.y, w = rect.w, h = rect.h }
    r.w = math.min(r.w, vf.w); r.h = math.min(r.h, vf.h)
    r.x = clamp(r.x, vf.x, vf.x + vf.w - r.w)
    r.y = clamp(r.y, vf.y, vf.y + vf.h - r.h)
    return r
end

local function computeTileFrame(tileName, tileCfg, scr, options)
    local vf = visibleFrameOfScreen(scr)
    local pad = (options and options.padding) or 0

    -- Base size from absolute or full visible frame
    local w = tileCfg.w or vf.w
    local h = tileCfg.h or vf.h

    -- Support percentage-based sizing relative to visible frame
    if tileCfg.wPct and type(tileCfg.wPct) == "number" then
        -- wPct is expected as 0.0..1.0
        w = math.floor(vf.w * tileCfg.wPct)
    end
    if tileCfg.hPct and type(tileCfg.hPct) == "number" then
        -- hPct is expected as 0.0..1.0
        h = math.floor(vf.h * tileCfg.hPct)
    end

    -- Ensure we don't overflow available area when scaleToFit is enabled
    if options and options.scaleToFitIfTooLarge then
        w = math.min(w, vf.w - 2 * pad)
        h = math.min(h, vf.h - 2 * pad)
    end

    local anchor = normalizeAnchor(tileName, tileCfg)
    local x, y
    if anchor == "top-center" then
        x = vf.x + math.floor((vf.w - w) / 2)
        y = vf.y + pad
    elseif anchor == "bottom-center" then
        x = vf.x + math.floor((vf.w - w) / 2)
        y = vf.y + vf.h - h - pad
    elseif anchor == "center" then
        x = vf.x + math.floor((vf.w - w) / 2)
        y = vf.y + math.floor((vf.h - h) / 2)
    elseif anchor == "top-left" then
        x = vf.x + pad
        y = vf.y + pad
    elseif anchor == "top-right" then
        x = vf.x + vf.w - w - pad
        y = vf.y + pad
    elseif anchor == "bottom-left" then
        x = vf.x + pad
        y = vf.y + vf.h - h - pad
    elseif anchor == "bottom-right" then
        x = vf.x + vf.w - w - pad
        y = vf.y + vf.h - h - pad
    else
        x = vf.x + pad
        y = vf.y + pad
    end

    return rectWithinVisibleFrame({ x = x, y = y, w = w, h = h }, vf)
end

-- Utility
local function toArray(x)
    if x == nil then return {} end
    if type(x) == "table" then return x end
    return { x }
end

local function isBundleId(s)
    return type(s) == "string" and s:find("%.") ~= nil and not s:find("%s")
end

local function getAppByIdentifier(identifier)
    if not identifier then return nil end
    if isBundleId(identifier) then
        local apps = hs.application.applicationsForBundleID(identifier)
        return (apps and apps[1]) or nil
    end
    return hs.application.get(identifier) or hs.appfinder.appFromName(identifier)
end

local function ensureAppRunning(identifier, options)
    local app = getAppByIdentifier(identifier)
    if app then return app end
    if not (options and options.autoLaunch) then return nil end
    if isBundleId(identifier) then
        hs.application.launchOrFocusByBundleID(identifier)
    else
        hs.application.launchOrFocus(identifier)
    end
    -- Non-blocking: return whatever handle is available now
    return getAppByIdentifier(identifier)
end

local function goodWindow(w)
    if not w then return false end
    if not w:isStandard() then return false end
    if w:isMinimized() then return false end
    if not w:isVisible() then return false end
    local f = w:frame()
    return f and f.w >= 8 and f.h >= 8
end

local function bestWindowForApp(app, opts)
    opts = opts or {}
    if not app then return nil end

    -- Try focused/main window first
    local w = app.focusedWindow and app:focusedWindow() or nil
    if goodWindow(w) then return w end

    local mw = app.mainWindow and app:mainWindow() or nil
    if goodWindow(mw) then return mw end

    -- If the app is hidden, reveal it without focusing
    if app.isHidden and app:isHidden() then
        pcall(function() app:unhide() end)
    end

    -- Scan all windows, unminimizing if needed
    local wins = (app.allWindows and app:allWindows()) or {}
    for _, cand in ipairs(wins) do
        if cand and cand.isMinimized and cand:isMinimized() then
            pcall(function() cand:unminimize() end)
        end
        if goodWindow(cand) then return cand end
    end

    -- Fallback: optionally create a new window via common menu items (non-blocking; placement will retry)
    if opts and opts.allowMenuCreate then
        local menuPaths = {
            { "File",   "New Window" },
            { "File",   "New" },
            { "File",   "New Tab" },
            { "Window", "New Window" },
        }
        for _, path in ipairs(menuPaths) do
            local ok = false
            pcall(function() ok = app:selectMenuItem(path) end)
            if ok then
                -- New window will appear shortly; let the caller retry placement asynchronously
                return nil
            end
        end
    end

    return nil
end

-- Move/Space without switching
local function moveWindowToScreen(w, scr)
    if not (w and scr) then return end
    local ws = w:screen()
    if not ws or ws:id() ~= scr:id() then
        w:moveToScreen(scr)
    end
end

local function moveWindowToSpace(w, spaceId)
    if not (w and spaceId) then return end
    pcall(hs.spaces.moveWindowToSpace, w, spaceId)
end

local function setWindowFrameAsync(w, frame)
    if not (w and frame) then return end
    -- Defer to next runloop to let macOS settle window moves (non-blocking)
    hs.timer.doAfter(0.01, function()
        if w and w.setFrame then w:setFrame(frame, 0) end
    end)
end

-- Deferred finalization when user switches to a space that has pending frames
local function ensureSpaceWatcher()
    if state.spaceWatcher then return end
    local function onSpaceChange()
        local cur = currentSpaceId()
        if not cur then return end
        local pending = state.pendingFramesBySpace[cur]
        if pending and #pending > 0 then
            for _, item in ipairs(pending) do
                local w, frame = item.win, item.frame
                if w and frame then setWindowFrameAsync(w, frame) end
            end
            state.pendingFramesBySpace[cur] = nil
        end
    end
    -- Use a minimal polling watcher: macOS doesn't expose a stable event for every change in all setups
    state.spaceWatcher = hs.timer.doEvery(0.25, onSpaceChange)
end

-- Ensure there are at least `requiredIndex` spaces on the given screen.
-- Non-blocking: attempts a best-effort creation if API is available, then relies on retries.
local function ensureSpacesCount(scr, requiredIndex, attemptsLeft, delay)
    attemptsLeft = attemptsLeft or 6
    delay = delay or 0.30
    if attemptsLeft < 0 then return end
    hs.timer.doAfter(0.01, function()
        local list = allSpacesForScreen(scr) or {}
        if #list >= requiredIndex then return end
        if hs.spaces and hs.spaces.addSpace then
            local okAdd = false
            local uuid = scr and scr.getUUID and scr:getUUID()
            if uuid then okAdd = pcall(hs.spaces.addSpace, uuid) end
            if not okAdd then okAdd = pcall(hs.spaces.addSpace, scr) end
            if not okAdd then
                log("spaces: addSpace failed; will retry")
            end
        else
            log("spaces: addSpace unavailable; will retry")
        end
        hs.timer.doAfter(delay, function()
            ensureSpacesCount(scr, requiredIndex, attemptsLeft - 1, delay)
        end)
    end)
end

-- Retry loop per tile without blocking
local function schedulePlacementRetry(args, attemptsLeft, delay)
    if not args then return end
    local attempts = tonumber(attemptsLeft) or (state.options.retryAttempts or DEFAULT_OPTIONS.retryAttempts)
    local d = delay or (state.options.retryInterval or DEFAULT_OPTIONS.retryInterval)
    hs.timer.doAfter(d, function()
        M._placeTile(args, attempts - 1)
    end)
end

-- Internal: place a single tile (called initially and via retries)
function M._placeTile(args, attemptsLeft)
    attemptsLeft = tonumber(attemptsLeft) or (state.options.retryAttempts or DEFAULT_OPTIONS.retryAttempts)
    if attemptsLeft < 0 then return end

    local scr         = args.screen
    local spaceIndex  = args.spaceIndex
    local frame       = args.frame
    local identifiers = args.identifiers

    -- Resolve spaceId from index; if missing, either create (if possible) or fallback to existing spaces
    local spaceId     = spaceIdForIndexOnScreen(scr, spaceIndex)
    if not spaceId then
        local list = allSpacesForScreen(scr) or {}
        if hs.spaces and hs.spaces.addSpace then
            -- Try to create missing spaces and retry later unless we can proceed via fullscreen
            if not args.fullscreen then
                ensureSpacesCount(scr, tonumber(spaceIndex) or 1)
                local nextDelay = state.options.retryInterval or DEFAULT_OPTIONS.retryInterval
                schedulePlacementRetry(args, attemptsLeft, nextDelay)
                return
            else
                log("placeTile: proceeding to fullscreen without known spaceId (will let macOS create the Space)")
            end
        else
            -- Fallback: reuse the closest existing space index and proceed without infinite retries
            if #list > 0 then
                local fallbackIdx = tonumber(spaceIndex) or 1
                if fallbackIdx < 1 then fallbackIdx = 1 end
                if fallbackIdx > #list then fallbackIdx = #list end
                spaceId = list[fallbackIdx]
                log("placeTile: addSpace unavailable; falling back to existing space index ", tostring(fallbackIdx))
            else
                if args.fullscreen then
                    -- No spaces API and no list; still allow fullscreen to create a space
                    log("placeTile: no spaceId available; continuing to fullscreen without space move")
                else
                    if not state._warnedNoAddSpace then
                        state._warnedNoAddSpace = true
                        pcall(function() hs.alert.show("Hammerspoon: cannot create Spaces; reusing existing spaces", 2) end)
                        log("placeTile: no spaces available to fallback to; giving up for this tile")
                    end
                    return
                end
            end
        end
    end

    -- Re-evaluate whether this is the current space at the time of placement
    local cur = currentSpaceId()
    local isCurrent = (cur and spaceId == cur) or false

    -- Try candidates in order
    for _, ident in ipairs(identifiers) do
        local app = ensureAppRunning(ident, state.options)
        local win = bestWindowForApp(app, { allowMenuCreate = args and args.fullscreen == true })
        if win then
            -- Move window to target screen
            moveWindowToScreen(win, scr)
            if args and args.fullscreen then
                -- Fullscreen path: robust multi-shot sequence for slow apps (e.g., Warp/Zed)
                local tries = (args.full_tries or 6)
                local delayBetween = math.max(0.30, state.options.retryInterval or DEFAULT_OPTIONS.retryInterval)

                local function attemptFullscreen(step)
                    if not (win and win.isFullScreen) then return end
                    if win:isFullScreen() then return end

                    -- Pre-activate/focus to ensure menu/keys go to the right app
                    local app = win:application()
                    if app and app.activate then pcall(function() app:activate() end) end
                    pcall(function() if win.focus then win:focus() end end)

                    -- 1) Try API toggle
                    if win.setFullScreen then win:setFullScreen(true) end

                    -- 2) After a short delay, try common menu fallbacks if still not fullscreen
                    hs.timer.doAfter(0.35, function()
                        if win and win.isFullScreen and not win:isFullScreen() then
                            local app = win:application()
                            if app and app.selectMenuItem then
                                app:selectMenuItem({ "Window", "Enter Full Screen" })
                                app:selectMenuItem({ "View", "Enter Full Screen" })
                            end
                            -- Additional fallback: try the standard macOS fullscreen key equivalent (Cmd+Ctrl+F)
                            if hs and hs.eventtap and hs.eventtap.keyStroke then
                                hs.eventtap.keyStroke({ "cmd", "ctrl" }, "F", 0)
                            end
                        end
                        -- 3) Re-check after another short delay; if still not fullscreen, retry via direct re-attempts before falling back
                        hs.timer.doAfter(0.4, function()
                            if win and win.isFullScreen and not win:isFullScreen() then
                                if step < tries then
                                    attemptFullscreen(step + 1)
                                else
                                    -- As a final measure, retry placement to re-attempt fullscreen
                                    args.full_tries = tries
                                    schedulePlacementRetry(args, attemptsLeft, delayBetween)
                                end
                            end
                        end)
                    end)
                end

                -- Kick off the first attempt shortly after moving to target screen
                hs.timer.doAfter(
                    (((args and tonumber(args.sequenceOrder)) and ((args.sequenceOrder - 1) * 0.6) or 0) + 0.05),
                    function() attemptFullscreen(1) end)
                return
            end
            -- Move window to target space quietly (no switching) if a valid spaceId is available
            if spaceId then
                moveWindowToSpace(win, spaceId)
                -- Apply frame either now (current space) or defer for when user visits that space
                if isCurrent then
                    setWindowFrameAsync(win, frame)
                else
                    state.pendingFramesBySpace[spaceId] = state.pendingFramesBySpace[spaceId] or {}
                    table.insert(state.pendingFramesBySpace[spaceId], { win = win, frame = frame })
                    ensureSpaceWatcher()
                end
            end
            return
        end
    end

    -- If no window yet, retry later (non-blocking)
    local nextDelay = state.options.retryInterval or DEFAULT_OPTIONS.retryInterval
    schedulePlacementRetry(args, attemptsLeft, nextDelay)
end

-- Apply a layout (no Space switching)
local function applyLayoutCore(layout)
    local scr = screenByTarget(layout.targetScreen or "focused")
    if not scr then return end

    local currentSpace = currentSpaceId()
    local currentIndex = indexOfSpaceOnScreen(scr, currentSpace)

    -- Build normalized mapping: index -> tileMap
    local normalized = {}
    for k, v in pairs(layout.space_layouts or {}) do
        local n = tonumber(k)
        if n then
            normalized[n] = v
        elseif tostring(k) == "current" then
            if currentIndex then normalized[currentIndex] = v end
        end
    end

    -- Place per space without switching (iterate spaces in numeric order)
    local spaceIndices = {}
    for i, _ in pairs(normalized) do table.insert(spaceIndices, i) end
    table.sort(spaceIndices, function(a, b) return (a or 0) < (b or 0) end)

    local _seqOrder = 0
    for _, idx in ipairs(spaceIndices) do
        local tileMap = normalized[idx]
        -- Shorthand: if a space is defined as a single-app list, treat it as a Full tile
        if type(tileMap) == "table" and tileMap[1] and tileMap[2] == nil and type(tileMap[1]) == "string" then
            tileMap = { ["Full"] = { tileMap[1] } }
        end
        -- Count total apps defined for this space to auto-fullscreen non-first spaces with a single app
        local totalApps = 0
        for _tn, _ids in pairs(tileMap or {}) do
            totalApps = totalApps + #toArray(_ids)
        end
        local singleAppOnly = (totalApps == 1)
        -- In single-app non-first space, pick exactly one tile to handle fullscreen placement
        local selectedTileName, selectedIds = nil, nil
        if idx ~= 1 and singleAppOnly then
            if tileMap["Full"] and #toArray(tileMap["Full"]) > 0 then
                selectedTileName = "Full"
                selectedIds = toArray(tileMap["Full"])
            else
                for _tn, _ids in pairs(tileMap or {}) do
                    local _arr = toArray(_ids)
                    if #_arr > 0 then
                        selectedTileName = _tn
                        selectedIds = _arr
                        break
                    end
                end
            end
        end

        for tileName, idList in pairs(tileMap or {}) do
            local tileCfg = state.tiles[tileName]
            local idsArr = toArray(idList)
            -- Skip empty tiles outright to avoid spurious retries
            if #idsArr > 0 then
                -- In single-app non-first spaces, only schedule one fullscreen placement (on the selected tile)
                if not (idx ~= 1 and singleAppOnly and tileName ~= selectedTileName) then
                    local frame = computeTileFrame(tileName, (tileCfg or { anchor = "top-left" }), scr, state.options)
                    log("applyLayoutCore: schedule place tile ", tileName, " on space ", idx)
                    _seqOrder = _seqOrder + 1
                    M._placeTile({
                        screen        = scr,
                        spaceIndex    = idx,
                        frame         = frame,
                        identifiers   = (idx ~= 1 and singleAppOnly) and selectedIds or idsArr,
                        fullscreen    = ((tileCfg and tileCfg.fullscreen == true) or (idx ~= 1 and singleAppOnly)) and
                            true or false,
                        sequenceOrder = _seqOrder,
                    }, state.options.retryAttempts or DEFAULT_OPTIONS.retryAttempts)
                end
            end
        end
    end

    -- Focus-after: focus a specific app if it has a window on the current space of the target screen (no switching)
    local focusIdent = layout.focusApp
    if focusIdent and type(focusIdent) == "string" then
        local app = getAppByIdentifier(focusIdent)
        local win = bestWindowForApp(app, { allowMenuCreate = false })
        if win and win.focus then
            -- Only focus if the window is on the same screen and on the current space for that screen
            local ws = win:screen()
            if ws and ws:id() == scr:id() then
                local okWS, wspaces = pcall(hs.spaces.windowSpaces, win)
                if not okWS or not wspaces then
                    -- Fallback: focus if on the same screen; avoid switching spaces intentionally
                    win:focus()
                else
                    for _, sid in ipairs(wspaces) do
                        if sid == currentSpace then
                            win:focus()
                            break
                        end
                    end
                end
            end
        end
    end
end

-- Public API
function M.applyLayout(name)
    if not state.configured then
        log("applyLayout before setup")
        return
    end
    local layout = nil
    for _, l in ipairs(state.layouts) do
        if l.name == name then
            layout = l; break
        end
    end
    if not layout then
        log("layout not found: ", name)
        return
    end
    applyLayoutCore(layout)
end

function M.teardown()
    -- Hotkeys
    if state.hotkeys then
        for _, hk in pairs(state.hotkeys) do
            if hk and hk.delete then pcall(function() hk:delete() end) end
        end
    end
    state.hotkeys = {}

    -- Watcher
    if state.spaceWatcher then
        pcall(function()
            local sw = state.spaceWatcher
            if sw and sw.stop then sw:stop() end
        end)
    end
    state.spaceWatcher = nil
    state.pendingFramesBySpace = {}

    -- Config
    state.tiles = {}
    state.layouts = {}
    state.options = DEFAULT_OPTIONS
    state.configured = false
    log("teardown complete")
end

function M.setup(cfg)
    if state.configured then M.teardown() end
    cfg           = cfg or {}
    state.tiles   = cfg.tiles or {}
    state.layouts = cfg.layouts or {}
    -- Merge options with defaults
    state.options = {}
    for k, v in pairs(DEFAULT_OPTIONS) do state.options[k] = v end
    for k, v in pairs(cfg.options or {}) do state.options[k] = v end

    -- Bind hotkeys
    state.hotkeys = {}
    for _, layout in ipairs(state.layouts) do
        local hk   = layout.hotkey or {}
        local mods = hk.mods or {}
        local key  = hk.key
        if key and type(mods) == "table" then
            local bound = hs.hotkey.bind(mods, key, function() M.applyLayout(layout.name) end)
            table.insert(state.hotkeys, bound)
        else
            log("layout missing hotkey: ", layout.name or "unknown")
        end
    end

    state.configured = true
    log("setup complete; layouts: ", #state.layouts)
end

return M
