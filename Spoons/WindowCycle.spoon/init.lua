--- === WindowCycle ===
---
--- Window/Space Cycler — Snappy & Production-Ready
---
--- Download: [https://github.com/AndrewDryga/spoons/raw/main/WindowCycle.spoon.zip](https://github.com/AndrewDryga/spoons/raw/main/WindowCycle.spoon.zip)

local obj = {}
obj.__index = obj

-- Metadata
obj.name = "WindowCycle"
obj.version = "1.1.0"
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

-- Default configuration values
local DEFAULT_CONFIG = {
    lockMs = 70,     -- input throttle window in ms (public name: debounceMs)
    hopSettle = 0.1, -- wait after a Space switch before reading windows (public: spaceHopDelay)
    keys = {
        mod = {},
        prev = "f18",
        next = "f19",
    },
}

-- Internal state
local state = {
    hotkeys = {},
    configured = false,
    hopping = false, -- true while a Space hop is settling
    hopTimer = nil,  -- pending post-hop focus timer (tracked so teardown can cancel it)
}

-- Config provided via setup()
local CONFIG = nil

-- Diagnostics go through obj.logger so its level controls visibility. Enable with
-- `spoon.WindowCycle.debug = true` (or :configure-time debug) or
-- `spoon.WindowCycle.logger.level = "debug"`.
local function log(...)
    local logger = obj.logger
    if logger and logger.d then
        logger.d(...)
    end
end

-- Safe cleanup helpers
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
-- rate-limiting key auto-repeat (a trailing debounce delayed every press and
-- never fired while a key was held down).
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

-- Window validation and helpers
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

    -- Then by Y position
    if frameA.y ~= frameB.y then
        return frameA.y < frameB.y
    end

    -- Then by title
    local titleA = getWindowTitle(a)
    local titleB = getWindowTitle(b)
    if titleA ~= titleB then
        return titleA < titleB
    end

    -- Finally by ID for stability
    return a:id() < b:id()
end

local function sortWindows(windows)
    table.sort(windows, compareWindows)
    return windows
end

local function getFocusedScreen()
    local frontWindow = hs.window.frontmostWindow()
    return (frontWindow and frontWindow:screen()) or hs.screen.mainScreen()
end

-- Window filter for current space (shared instance — never rebuilt per call)
local windowFilter = hs.window.filter.defaultCurrentSpace

local function getWindowsOnCurrentSpace(screen)
    if not screen then
        return {}
    end

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

-- Space navigation helpers
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

    -- Calculate target space index
    local targetIndex
    if direction == "next" then
        targetIndex = currentIndex < #allSpaces and currentIndex + 1 or 1
    else -- "prev"
        targetIndex = currentIndex > 1 and currentIndex - 1 or #allSpaces
    end

    local targetSpaceId = allSpaces[targetIndex]

    -- Mark busy so rapid presses don't race the in-flight Space transition.
    state.hopping = true

    -- Navigate to space and then focus the appropriate window
    local ok, err = pcall(function()
        hs.spaces.gotoSpace(targetSpaceId)

        -- macOS needs a beat after gotoSpace before the window list for the new
        -- Space is readable — this delay is load-bearing, not cosmetic.
        local settleTime = (CONFIG and CONFIG.hopSettle) or DEFAULT_CONFIG.hopSettle
        state.hopTimer = hs.timer.doAfter(settleTime, function()
            -- Release the lock first so a thrown focus call can't wedge cycling.
            state.hopping = false
            state.hopTimer = nil

            local focusOk, focusErr = pcall(function()
                local windows = getWindowsOnCurrentSpace(screen)
                local targetWindow = nil

                if windows and #windows > 0 then
                    if preferredPosition == "first" then
                        targetWindow = windows[1]
                    elseif preferredPosition == "last" then
                        targetWindow = windows[#windows]
                    end
                end

                if targetWindow then
                    targetWindow:raise()
                    targetWindow:focus()
                end
            end)
            if not focusOk then
                log("Failed to focus after hop:", focusErr)
            end
        end)
    end)

    if not ok then
        -- gotoSpace failed before we scheduled the settle timer; release the lock.
        state.hopping = false
        log("Failed to hop to space:", err)
    end
end

-- Window cycling logic
local function findCurrentWindowIndex(windows, currentWindow)
    if not currentWindow then return nil end

    for index, window in ipairs(windows) do
        if window == currentWindow then
            return index
        end
    end

    return nil
end

local function cycleToWindow(direction)
    -- Ignore presses while a Space hop is settling to avoid racing the transition.
    if state.hopping then return end

    local screen = getFocusedScreen()
    if not screen then return end

    local windows = getWindowsOnCurrentSpace(screen)
    local spaceIndex, spaces = getCurrentSpaceIndex(screen)
    local multipleSpaces = spaces and #spaces > 1

    -- If no windows, hop only if multiple spaces; otherwise do nothing
    if #windows == 0 then
        if multipleSpaces then
            local preferredPosition = (direction == "next") and "first" or "last"
            hopToSpace(direction, preferredPosition, screen, spaceIndex, spaces)
        end
        return
    end

    -- Find current window position
    local currentWindow = hs.window.frontmostWindow()
    local windowIndex = findCurrentWindowIndex(windows, currentWindow)

    -- Determine target window
    local targetWindow = nil

    if direction == "next" then
        if not windowIndex or windowIndex >= #windows then
            -- Wrap: hop only if multiple spaces, otherwise wrap within current space
            if multipleSpaces then
                hopToSpace("next", "first", screen, spaceIndex, spaces)
            else
                targetWindow = windows[1]
            end
        else
            -- Move to next window
            targetWindow = windows[windowIndex + 1]
        end
    else -- "prev"
        if not windowIndex or windowIndex <= 1 then
            -- Wrap: hop only if multiple spaces, otherwise wrap within current space
            if multipleSpaces then
                hopToSpace("prev", "last", screen, spaceIndex, spaces)
            else
                targetWindow = windows[#windows]
            end
        else
            -- Move to previous window
            targetWindow = windows[windowIndex - 1]
        end
    end

    -- Focus target window if found
    if targetWindow then
        local ok, err = pcall(function()
            targetWindow:raise()
            targetWindow:focus()
        end)
        if not ok then
            log("Failed to focus window:", err)
        end
    end
end

-- Hotkey binding
local function bindHotkeys()
    if not CONFIG then
        log("CONFIG not initialized in bindHotkeys")
        return
    end

    local lockSeconds = CONFIG.lockMs / 1000

    -- Throttle cycling so key auto-repeat can't outrun the UI, while keeping the
    -- first press instant.
    local cyclePrevThrottled = throttle(lockSeconds, function()
        cycleToWindow("prev")
    end)

    local cycleNextThrottled = throttle(lockSeconds, function()
        cycleToWindow("next")
    end)

    -- Bind hotkeys
    if hs.hotkey and hs.hotkey.bind then
        -- Previous window/space
        if CONFIG.keys and CONFIG.keys.prev then
            local mods = CONFIG.keys.prevMods or CONFIG.keys.mod or {}
            local prevHotkey = hs.hotkey.bind(
                mods,
                CONFIG.keys.prev,
                cyclePrevThrottled
            )
            if prevHotkey then
                state.hotkeys.prev = prevHotkey
            end
        end

        -- Next window/space
        if CONFIG.keys and CONFIG.keys.next then
            local mods = CONFIG.keys.nextMods or CONFIG.keys.mod or {}
            local nextHotkey = hs.hotkey.bind(
                mods,
                CONFIG.keys.next,
                cycleNextThrottled
            )
            if nextHotkey then
                state.hotkeys.next = nextHotkey
            end
        end
    end
end

-- Original module setup function
local teardown
local function setup(config)
    -- If already configured, teardown and re-bind
    if state.configured then
        teardown()
    end

    -- Merge config with defaults
    CONFIG = config or {}

    -- Raise the logger to debug when requested. Setting
    -- `spoon.WindowCycle.logger.level = "debug"` directly works too, since all
    -- diagnostics are emitted through obj.logger.
    if CONFIG.debug == true then
        pcall(function() obj.logger.setLogLevel('debug') end)
    end

    -- Apply defaults for missing values
    CONFIG.lockMs = type(CONFIG.lockMs) == "number" and CONFIG.lockMs or DEFAULT_CONFIG.lockMs
    CONFIG.hopSettle = type(CONFIG.hopSettle) == "number" and CONFIG.hopSettle or DEFAULT_CONFIG.hopSettle

    CONFIG.keys = CONFIG.keys or {}
    CONFIG.keys.mod = CONFIG.keys.mod or DEFAULT_CONFIG.keys.mod
    CONFIG.keys.prev = CONFIG.keys.prev or DEFAULT_CONFIG.keys.prev
    CONFIG.keys.next = CONFIG.keys.next or DEFAULT_CONFIG.keys.next

    bindHotkeys()
    state.configured = true
    log("Setup complete")
end

function teardown()
    -- Cancel any pending post-hop focus timer so it can't fire after stop.
    if state.hopTimer then
        pcall(function() state.hopTimer:stop() end)
        state.hopTimer = nil
    end
    state.hopping = false

    -- Delete all hotkeys
    for name, hotkey in pairs(state.hotkeys) do
        safeDelete(hotkey)
        log("Deleted hotkey:", name)
    end

    state.hotkeys = {}
    state.configured = false
    log("Teardown complete")
end

-- Spoon API
function obj:init()
    return self
end

function obj:start()
    setup({
        debug = self.debug or false,
        lockMs = self.debounceMs or DEFAULT_CONFIG.lockMs,
        hopSettle = self.spaceHopDelay or DEFAULT_CONFIG.hopSettle,
        keys = self._keys or DEFAULT_CONFIG.keys
    })
    return self
end

function obj:stop()
    teardown()
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

-- Public configuration variables (for compatibility)
obj.debug = false
obj.debounceMs = DEFAULT_CONFIG.lockMs
obj.spaceHopDelay = DEFAULT_CONFIG.hopSettle

return obj
