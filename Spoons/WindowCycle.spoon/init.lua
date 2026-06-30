--- === WindowCycle ===
---
--- Window/Space Cycler — Snappy & Production-Ready
---
--- Download: [https://github.com/AndrewDryga/spoons/raw/main/WindowCycle.spoon.zip](https://github.com/AndrewDryga/spoons/raw/main/WindowCycle.spoon.zip)

local obj = {}
obj.__index = obj

-- Metadata
obj.name = "WindowCycle"
obj.version = "1.2.0"
obj.author = "Andrew Dryga"
obj.homepage = "https://github.com/AndrewDryga/spoons"
obj.license = "MIT - https://opensource.org/licenses/MIT"

---@diagnostic disable-next-line: undefined-global, lowercase-global
hs = hs or {}

-- Logger
obj.logger = hs.logger.new('WindowCycle')

-- Constants
local MIN_WINDOW_SIZE = 8     -- ignore tiny utility/HUD windows (px)
local POSITION_TOLERANCE = 10 -- X band width (px) for left-to-right column grouping

-- Space-hop tuning. The hop is event-driven: hs.spaces.gotoSpace blocks until the
-- Space transition finishes, then we poll to (a) pick a window verified to live on
-- the target Space and (b) re-assert focus until it actually sticks, since macOS
-- tends to keep its own most-recently-used window focused after a switch. These
-- bound that post-gotoSpace polling.
local HOP_POLL_INTERVAL = 0.02 -- s, how often to re-check while a hop settles
local HOP_POLL_TIMEOUT  = 0.8  -- s, overall cap on post-gotoSpace polling (fullscreen settles can run ~0.4s)
local HOP_EMPTY_GRACE   = 0.15 -- s, how long to wait for a focusable window before accepting an empty Space
local HOP_FOCUS_RETRIES = 4    -- times to re-assert focus if macOS re-focuses its own window over ours

-- Default configuration. Users override these via the public `obj.<name>` fields
-- (see the bottom of this file); they are read into `config` at :start().
local DEFAULTS = {
    debounceMs = 70,   -- leading-edge throttle window for cycling (ms)
    spaceHopDelay = 0, -- minimum settle floor after a Space hop (s); 0 = fully event-driven
    keys = {
        prev = "f18",
        next = "f19",
    },
}

-- Resolved configuration snapshot, taken from the public fields at :start().
local config = nil

-- Runtime state
local state = {
    hotkeys = {},
    configured = false,
    hopping = false, -- true while a Space hop is settling
    hopTimer = nil,  -- pending post-hop poll timer (tracked so :stop() can cancel it)
}

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

-- Diagnostics go through obj.logger so its level controls visibility. Enable with
-- `spoon.WindowCycle.debug = true` or `spoon.WindowCycle.logger.level = "debug"`.
local function log(...)
    local logger = obj.logger
    if logger and logger.d then
        logger.d(...)
    end
end

local function num(value, default)
    return type(value) == "number" and value or default
end

local function safeDelete(hotkey)
    if hotkey and type(hotkey.delete) == "function" then
        pcall(hotkey.delete, hotkey)
    end
end

-- Normalize a modifiers list, dropping empty-string entries so callers can pass
-- `{}` or `{ "" }` interchangeably to mean "no modifier".
local function normalizeMods(mods)
    if type(mods) ~= "table" then return {} end
    local out = {}
    for _, m in ipairs(mods) do
        if type(m) == "string" and m ~= "" then
            out[#out + 1] = m
        end
    end
    return out
end

-- Leading-edge throttle: run immediately on the first call, then ignore further
-- calls for `intervalSeconds`. Keeps a single press instant while still
-- rate-limiting key auto-repeat.
local function throttle(intervalSeconds, fn)
    local lastFire = 0
    return function(...)
        local now = hs.timer.secondsSinceEpoch()
        if (now - lastFire) < intervalSeconds then
            return
        end
        lastFire = now
        fn(...)
    end
end

--------------------------------------------------------------------------------
-- Window enumeration and ordering
--------------------------------------------------------------------------------

local function isValidWindow(window)
    if not window then return false end
    if not (window:isVisible() and window:isStandard() and not window:isMinimized()) then
        return false
    end

    local app = window:application()
    if app and app:isHidden() then
        return false
    end

    local frame = window:frame()
    return frame and frame.w >= MIN_WINDOW_SIZE and frame.h >= MIN_WINDOW_SIZE
end

local function getWindowTitle(window)
    if not window then return "Window" end

    local app = window:application()
    local appName = app and app:name() or ""
    local title = window:title() or ""

    if #appName > 0 and #title > 0 then
        return appName .. ": " .. title
    elseif #appName > 0 then
        return appName
    elseif #title > 0 then
        return title
    else
        return "Window"
    end
end

local function compareWindows(a, b)
    local frameA, frameB = a:frame(), b:frame()

    -- Group windows into vertical bands by X so a column sorts top-to-bottom.
    -- Quantizing to a fixed band keeps the comparator transitive; a plain
    -- |Δx| > tolerance test is NOT transitive and can make table.sort raise
    -- "invalid order function for sorting" on certain layouts.
    local bandA = math.floor(frameA.x / POSITION_TOLERANCE)
    local bandB = math.floor(frameB.x / POSITION_TOLERANCE)
    if bandA ~= bandB then
        return bandA < bandB
    end

    if frameA.y ~= frameB.y then
        return frameA.y < frameB.y
    end

    local titleA = getWindowTitle(a)
    local titleB = getWindowTitle(b)
    if titleA ~= titleB then
        return titleA < titleB
    end

    return a:id() < b:id() -- final tiebreak for a fully stable order
end

local function sortWindows(windows)
    table.sort(windows, compareWindows)
    return windows
end

local function getFocusedScreen()
    local frontWindow = hs.window.frontmostWindow()
    return (frontWindow and frontWindow:screen()) or hs.screen.mainScreen()
end

-- Shared filter for the current Space (never rebuilt per call — that would be slow).
local windowFilter = hs.window.filter.defaultCurrentSpace

local function getWindowsOnCurrentSpace(screen)
    if not screen then return {} end

    local windows = {}
    local screenId = screen:id()

    local allWindows = windowFilter and windowFilter.getWindows and windowFilter:getWindows()
    if allWindows then
        for _, window in ipairs(allWindows) do
            -- Guard against windows that died between enumeration and inspection.
            local ok, keep = pcall(function()
                local windowScreen = window:screen()
                return windowScreen and windowScreen:id() == screenId and isValidWindow(window)
            end)
            if ok and keep then
                table.insert(windows, window)
            end
        end
    end

    return sortWindows(windows)
end

--------------------------------------------------------------------------------
-- Space navigation
--------------------------------------------------------------------------------

local function getCurrentSpaceIndex(screen)
    if not screen then return nil, nil end

    local currentSpaceId = hs.spaces.focusedSpace()
    local spacesByScreen = hs.spaces.allSpaces()
    if not currentSpaceId or not spacesByScreen then
        return nil, nil
    end

    local screenSpaces = spacesByScreen[screen:getUUID()]
    if not screenSpaces then
        return nil, nil
    end

    for index, spaceId in ipairs(screenSpaces) do
        if spaceId == currentSpaceId then
            return index, screenSpaces
        end
    end

    return nil, screenSpaces
end

-- Pick the first/last window from a list and confirm it lives on `targetSpaceId`.
-- Returns the chosen window once it verifies, or nil if the chosen end isn't (yet)
-- on the target Space. The verification guards against the window filter briefly
-- returning stale (previous-Space) windows right after a hop — which is what lets
-- us drop a fixed settle delay instead of just guessing a smaller one.
local function selectVerifiedWindow(windows, targetSpaceId, preferredPosition)
    if #windows == 0 then return nil end

    local target = (preferredPosition == "last") and windows[#windows] or windows[1]
    if not target then return nil end

    -- Confirm the candidate is on the target Space. If the API is unavailable or
    -- errors, fall through and accept it best-effort.
    if targetSpaceId and hs.spaces and hs.spaces.windowSpaces then
        local ok, spaces = pcall(hs.spaces.windowSpaces, target)
        if ok and type(spaces) == "table" then
            for _, sid in ipairs(spaces) do
                if sid == targetSpaceId then return target end
            end
            return nil -- chosen end is on a different Space (stale) — not ready yet
        end
    end

    return target
end

-- Verbose diagnostics for a completed hop (built only when debug logging is on).
-- Logs the ordered window list with titles + per-window Space membership, which
-- window we chose, how many times we had to re-assert focus, whether it stuck, and
-- what macOS had focused on arrival — enough to tell a wrong-selection bug from
-- macOS re-focusing its own most-recently-used window over ours.
local function logHop(info)
    local windows = info.windows or {}
    log(string.format(
        "hop %s -> space %s: %s in %.0f ms (%d polls, %d focus attempts, confirmed=%s); preferred=%s; %d window(s); chose=%s",
        tostring(info.direction), tostring(info.targetSpaceId), info.reason, info.ms, info.polls,
        info.attempts, tostring(info.confirmed), tostring(info.preferredPosition), #windows,
        info.chosen and getWindowTitle(info.chosen) or "<none>"))
    for i, w in ipairs(windows) do
        local onTarget = "?"
        if hs.spaces and hs.spaces.windowSpaces then
            local ok, sp = pcall(hs.spaces.windowSpaces, w)
            if ok and type(sp) == "table" then
                onTarget = "no"
                for _, sid in ipairs(sp) do
                    if sid == info.targetSpaceId then onTarget = "yes"; break end
                end
            end
        end
        log(string.format("    [%d] onTarget=%-3s %s%s", i, onTarget, getWindowTitle(w),
            (w == info.chosen) and "   <== focused" or ""))
    end
    log("    frontmost on arrival: " .. (info.frontBefore and getWindowTitle(info.frontBefore) or "nil"))
end

local function windowId(window)
    if not window then return nil end
    local ok, id = pcall(function() return window:id() end)
    return ok and id or nil
end

local function hopToSpace(direction, preferredPosition, screen, currentIndex, allSpaces)
    screen = screen or getFocusedScreen()
    if not screen then return end

    -- Reuse the caller's already-computed space info when provided.
    if not currentIndex or not allSpaces then
        currentIndex, allSpaces = getCurrentSpaceIndex(screen)
    end
    if not currentIndex or not allSpaces or #allSpaces == 0 then
        log("Unable to get space information")
        return
    end

    local targetIndex
    if direction == "next" then
        targetIndex = currentIndex < #allSpaces and currentIndex + 1 or 1
    else -- "prev"
        targetIndex = currentIndex > 1 and currentIndex - 1 or #allSpaces
    end
    local targetSpaceId = allSpaces[targetIndex]

    -- Mark busy so rapid presses don't race the in-flight Space transition.
    state.hopping = true

    if config.debug then
        log(string.format("hop %s: space %s -> %s (preferred=%s)",
            tostring(direction), tostring(allSpaces[currentIndex]), tostring(targetSpaceId),
            tostring(preferredPosition)))
    end

    local okGoto, err = pcall(hs.spaces.gotoSpace, targetSpaceId)
    if not okGoto then
        state.hopping = false -- gotoSpace failed; release the lock
        log("Failed to hop to space:", err)
        return
    end

    -- gotoSpace BLOCKS until the Space transition finishes, so start the settle
    -- budget AFTER it returns. (Measuring from before lets the ~0.5s transition eat
    -- the whole timeout, so we'd give up before ever focusing our window.)
    local startedAt = hs.timer.secondsSinceEpoch()
    local deadline = startedAt + HOP_POLL_TIMEOUT
    local settleFloor = config.spaceHopDelay
    local arrivalTime = nil
    local polls = 0
    local attempts = 0
    local chosen = nil
    local chosenWindows = nil
    local frontBefore = config.debug and hs.window.frontmostWindow() or nil

    -- Has the screen actually switched to the target Space yet?
    local function arrived()
        if not (hs.spaces and hs.spaces.activeSpaceOnScreen) then
            return true -- can't detect; rely on window verification
        end
        local okA, active = pcall(hs.spaces.activeSpaceOnScreen, screen)
        return okA and active == targetSpaceId
    end

    local function finish(reason, confirmed, now)
        -- Release the lock first so anything that throws can't wedge cycling.
        state.hopping = false
        state.hopTimer = nil
        if config.debug then
            logHop({
                direction = direction, targetSpaceId = targetSpaceId, preferredPosition = preferredPosition,
                windows = chosenWindows, chosen = chosen, frontBefore = frontBefore, reason = reason,
                confirmed = confirmed, ms = (now - startedAt) * 1000, polls = polls, attempts = attempts,
            })
        end
    end

    local function step()
        local now = hs.timer.secondsSinceEpoch()
        polls = polls + 1

        -- Phase 1: confirm arrival, then pick a window verified to be on the target.
        if not chosen then
            if not arrivalTime and arrived() then arrivalTime = now end
            if arrivalTime and (now - arrivalTime) >= settleFloor then
                local windows = getWindowsOnCurrentSpace(screen)
                local pick = selectVerifiedWindow(windows, targetSpaceId, preferredPosition)
                if pick then
                    chosen = pick
                    chosenWindows = windows
                elseif (now - arrivalTime) >= HOP_EMPTY_GRACE then
                    chosenWindows = windows
                    return finish("grace-no-window", false, now) -- empty Space: nothing to focus
                end
            end
        end

        -- Phase 2: focus the chosen window and re-assert until it actually sticks.
        -- (After a Space switch macOS often keeps its own most-recently-used window
        -- focused; we poll until the frontmost window is the one we want.)
        if chosen then
            if windowId(hs.window.frontmostWindow()) == windowId(chosen) then
                return finish("focused", true, now)
            end
            if attempts >= HOP_FOCUS_RETRIES then
                return finish("focus-unconfirmed", false, now)
            end
            attempts = attempts + 1
            pcall(function()
                chosen:raise()
                chosen:focus()
            end)
        end

        if now >= deadline then
            return finish(chosen and "timeout-unconfirmed" or "timeout-no-window", false, now)
        end

        state.hopTimer = hs.timer.doAfter(HOP_POLL_INTERVAL, step)
    end

    step()
end

--------------------------------------------------------------------------------
-- Window cycling
--------------------------------------------------------------------------------

local function findCurrentWindowIndex(windows, currentWindow)
    if not currentWindow then return nil end
    for index, window in ipairs(windows) do
        if window == currentWindow then
            return index
        end
    end
    return nil
end

local function focusWindow(window)
    if not window then return end
    local ok, err = pcall(function()
        window:raise()
        window:focus()
    end)
    if not ok then
        log("Failed to focus window:", err)
    end
end

local function cycleToWindow(direction)
    -- Ignore presses while a Space hop is settling to avoid racing the transition.
    if state.hopping then return end

    local screen = getFocusedScreen()
    if not screen then return end

    local windows = getWindowsOnCurrentSpace(screen)
    local spaceIndex, spaces = getCurrentSpaceIndex(screen)
    local multipleSpaces = spaces and #spaces > 1

    -- No windows here: hop to an adjacent Space if there is one, else do nothing.
    if #windows == 0 then
        if multipleSpaces then
            hopToSpace(direction, (direction == "next") and "first" or "last", screen, spaceIndex, spaces)
        end
        return
    end

    local windowIndex = findCurrentWindowIndex(windows, hs.window.frontmostWindow())

    if direction == "next" then
        if not windowIndex or windowIndex >= #windows then
            -- Past the last window: hop to the next Space, or wrap within this one.
            if multipleSpaces then
                hopToSpace("next", "first", screen, spaceIndex, spaces)
            else
                focusWindow(windows[1])
            end
        else
            focusWindow(windows[windowIndex + 1])
        end
    else -- "prev"
        if not windowIndex or windowIndex <= 1 then
            -- Before the first window: hop to the previous Space, or wrap.
            if multipleSpaces then
                hopToSpace("prev", "last", screen, spaceIndex, spaces)
            else
                focusWindow(windows[#windows])
            end
        else
            focusWindow(windows[windowIndex - 1])
        end
    end
end

-- Bind the configured hotkeys to throttled cycling functions.
local function bindHotkeys()
    local interval = config.debounceMs / 1000
    state.hotkeys.prev = hs.hotkey.bind(config.keys.prevMods, config.keys.prev,
        throttle(interval, function() cycleToWindow("prev") end))
    state.hotkeys.next = hs.hotkey.bind(config.keys.nextMods, config.keys.next,
        throttle(interval, function() cycleToWindow("next") end))
end

--------------------------------------------------------------------------------
-- Spoon API
--------------------------------------------------------------------------------

function obj:init()
    return self
end

function obj:start()
    if state.configured then self:stop() end -- re-bind cleanly on reconfigure

    -- Snapshot the public configuration fields.
    local keys = self._keys or {}
    config = {
        debug = self.debug == true,
        debounceMs = num(self.debounceMs, DEFAULTS.debounceMs),
        spaceHopDelay = num(self.spaceHopDelay, DEFAULTS.spaceHopDelay),
        keys = {
            prev     = keys.prev or DEFAULTS.keys.prev,
            prevMods = keys.prevMods or {},
            next     = keys.next or DEFAULTS.keys.next,
            nextMods = keys.nextMods or {},
        },
    }

    -- Honor `spoon.WindowCycle.debug = true` (the logger.level setter works too).
    if config.debug then
        pcall(function() obj.logger.setLogLevel('debug') end)
    end

    bindHotkeys()
    state.configured = true
    log("Started")
    return self
end

function obj:stop()
    -- Cancel any pending post-hop poll timer so it can't fire after stop.
    if state.hopTimer then
        pcall(function() state.hopTimer:stop() end)
        state.hopTimer = nil
    end
    state.hopping = false

    for _, hotkey in pairs(state.hotkeys) do
        safeDelete(hotkey)
    end
    state.hotkeys = {}
    state.configured = false
    log("Stopped")
    return self
end

function obj:bindHotkeys(mapping)
    if mapping then
        self._keys = self._keys or {}
        if mapping.prev then
            local mods, key = table.unpack(mapping.prev)
            self._keys.prevMods = normalizeMods(mods)
            self._keys.prev = key
        end
        if mapping.next then
            local mods, key = table.unpack(mapping.next)
            self._keys.nextMods = normalizeMods(mods)
            self._keys.next = key
        end
    end
    return self
end

-- Public configuration (set these on the spoon before calling :start())
obj.debug = false
obj.debounceMs = DEFAULTS.debounceMs
obj.spaceHopDelay = DEFAULTS.spaceHopDelay

return obj
