-- window_tile_organizer.lua
-- Arrange multiple app windows into named tiles with a single hotkey (preset)
-- Clean schema: layouts use space_layouts, optional focusSpaceTile, no Space switching,
-- robust screen handling, non-blocking placement and retries.
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
--         focusSpaceTile = { "current", "Top" }, -- focus a tile on current space after arranging, or nil to restore focus
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
    local all = hs.spaces.allSpaces()
    return (all and scr and all[scr:getUUID()]) or nil
end

local function currentSpaceId()
    local ok, sid = pcall(hs.spaces.focusedSpace)
    return ok and sid or nil
end

local function spaceIdForIndexOnScreen(scr, idx)
    local list = allSpacesForScreen(scr)
    if not list or #list == 0 then return nil end
    if type(idx) ~= "number" then return nil end
    if idx < 1 then idx = 1 end
    if idx > #list then idx = #list end
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
    local w = tileCfg.w or vf.w
    local h = tileCfg.h or vf.h
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

local function bestWindowForApp(app)
    if not app then return nil end
    local w = app:focusedWindow()
    if goodWindow(w) then return w end
    local wins = app:allWindows() or {}
    for _, cand in ipairs(wins) do
        if goodWindow(cand) then return cand end
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

-- Retry loop per tile without blocking
local function schedulePlacementRetry(args, attemptsLeft, delay)
    hs.timer.doAfter(delay, function()
        M._placeTile(args, attemptsLeft - 1)
    end)
end

-- Internal: place a single tile (called initially and via retries)
function M._placeTile(args, attemptsLeft)
    if attemptsLeft < 0 then return end

    local scr         = args.screen
    local spaceId     = args.spaceId
    local isCurrent   = args.isCurrentSpace
    local frame       = args.frame
    local identifiers = args.identifiers

    -- Try candidates in order
    for _, ident in ipairs(identifiers) do
        local app = ensureAppRunning(ident, state.options)
        local win = bestWindowForApp(app)
        if win then
            -- Move window to target screen
            moveWindowToScreen(win, scr)
            -- Move window to target space quietly (no switching)
            if spaceId then moveWindowToSpace(win, spaceId) end
            -- Apply frame either now (current space) or defer for when user visits that space
            if isCurrent then
                setWindowFrameAsync(win, frame)
            else
                state.pendingFramesBySpace[spaceId] = state.pendingFramesBySpace[spaceId] or {}
                table.insert(state.pendingFramesBySpace[spaceId], { win = win, frame = frame })
                ensureSpaceWatcher()
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

    -- Place per space without switching
    for idx, tileMap in pairs(normalized) do
        local spaceId = spaceIdForIndexOnScreen(scr, idx)
        if spaceId then
            local isCurrent = (currentSpace and spaceId == currentSpace) or false
            for tileName, idList in pairs(tileMap or {}) do
                local tileCfg = state.tiles[tileName]
                if tileCfg then
                    local frame = computeTileFrame(tileName, tileCfg, scr, state.options)
                    M._placeTile({
                        screen         = scr,
                        spaceId        = spaceId,
                        isCurrentSpace = isCurrent,
                        frame          = frame,
                        identifiers    = toArray(idList),
                    }, state.options.retryAttempts or DEFAULT_OPTIONS.retryAttempts)
                else
                    log("unknown tile: ", tileName)
                end
            end
        else
            log("space index not found on screen: ", idx)
        end
    end

    -- Focus-after: only if target space equals current (no switching)
    local fst = layout.focusSpaceTile
    if fst and fst[1] and fst[2] then
        local idx
        if fst[1] == "current" then
            idx = currentIndex
        else
            idx = tonumber(fst[1])
        end
        if idx and currentIndex and idx == currentIndex then
            local tileName = fst[2]
            -- Try to focus a window that matches the tile on current space (best effort)
            local tileMap = normalized[idx]
            local idList = tileMap and tileMap[tileName]
            if idList then
                for _, ident in ipairs(toArray(idList)) do
                    local app = getAppByIdentifier(ident)
                    local win = bestWindowForApp(app)
                    if win and win.focus then
                        win:focus(); break
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
