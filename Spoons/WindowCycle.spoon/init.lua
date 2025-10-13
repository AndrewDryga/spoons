--- === WindowCycle ===
---
--- Window/Space Cycler — Snappy & Production-Ready
---
--- Download: [https://github.com/AndrewDryga/spoons/raw/main/WindowCycle.spoon.zip](https://github.com/AndrewDryga/spoons/raw/main/WindowCycle.spoon.zip)

local obj = {}
obj.__index = obj

-- Metadata
obj.name = "WindowCycle"
obj.version = "1.0.0"
obj.author = "Andrew Dryga"
obj.homepage = "https://github.com/AndrewDryga/spoons"
obj.license = "MIT - https://opensource.org/licenses/MIT"

---@diagnostic disable-next-line: undefined-global, lowercase-global
hs = hs or {}

-- Logger
obj.logger = hs.logger.new('WindowCycle')

-- Constants
local MIN_WINDOW_SIZE = 8
local POSITION_TOLERANCE = 10

-- Default configuration values
local DEFAULT_CONFIG = {
    lockMs = 70,
    hopSettle = 0.1,
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
}

-- Config provided via setup()
local CONFIG = nil
local LOG = false

local function log(...)
    if LOG then
        print("[window_cycle]", ...)
    end
end

-- Safe cleanup helpers
local function safeDelete(hotkey)
    if hotkey and type(hotkey.delete) == "function" then
        pcall(hotkey.delete, hotkey)
    end
end

-- Debounce helper to prevent rapid cycling
local function debounce(intervalSeconds, fn)
    local timer = nil

    return function(...)
        local args = table.pack(...)

        if timer then
            timer:stop()
        end

        timer = hs.timer.doAfter(intervalSeconds, function()
            fn(table.unpack(args, 1, args.n))
        end)
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

    -- Sort by X position first
    if math.abs(frameA.x - frameB.x) > POSITION_TOLERANCE then
        return frameA.x < frameB.x
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

-- Window filter for current space
local windowFilter = hs.window.filter.defaultCurrentSpace

local function getWindowsOnCurrentSpace(screen)
    if not screen or not screen.id then
        return {}
    end

    local windows = {}
    local screenId = screen:id()

    if windowFilter and windowFilter.getWindows then
        local allWindows = windowFilter:getWindows()
        if allWindows then
            for _, window in ipairs(allWindows) do
                if window and window.screen then
                    local windowScreen = window:screen()
                    if windowScreen and windowScreen.id and windowScreen:id() == screenId then
                        if isValidWindow(window) then
                            table.insert(windows, window)
                        end
                    end
                end
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

local function navigateToSpace(targetSpaceId, targetWindow)
    if not targetSpaceId then return end

    local ok, err = pcall(function()
        hs.spaces.gotoSpace(targetSpaceId)

        if targetWindow then
            local settleTime = (CONFIG and CONFIG.hopSettle) or DEFAULT_CONFIG.hopSettle
            hs.timer.doAfter(settleTime, function()
                if targetWindow and targetWindow.raise and targetWindow.focus then
                    targetWindow:raise()
                    targetWindow:focus()
                end
            end)
        elseif CONFIG and CONFIG.hopSettle and CONFIG.hopSettle > 0 then
            -- Try to find and focus a window after settling
            hs.timer.doAfter(CONFIG.hopSettle, function()
                local screen = getFocusedScreen()
                local windows = getWindowsOnCurrentSpace(screen)
                if windows and #windows > 0 then
                    local firstWindow = windows[1]
                    if firstWindow and firstWindow.raise and firstWindow.focus then
                        firstWindow:raise()
                        firstWindow:focus()
                    end
                end
            end)
        end
    end)

    if not ok then
        log("Failed to navigate to space:", err)
    end
end

local function hopToSpace(direction, preferredPosition)
    local screen = getFocusedScreen()
    if not screen then return end

    local currentIndex, allSpaces = getCurrentSpaceIndex(screen)
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

    -- Navigate to space and then focus the appropriate window
    local ok, err = pcall(function()
        hs.spaces.gotoSpace(targetSpaceId)

        local settleTime = (CONFIG and CONFIG.hopSettle) or DEFAULT_CONFIG.hopSettle
        hs.timer.doAfter(settleTime, function()
            local windows = getWindowsOnCurrentSpace(screen)
            local targetWindow = nil

            if windows and #windows > 0 then
                if preferredPosition == "first" then
                    targetWindow = windows[1]
                elseif preferredPosition == "last" then
                    targetWindow = windows[#windows]
                end
            end

            if targetWindow and targetWindow.raise and targetWindow.focus then
                targetWindow:raise()
                targetWindow:focus()
            end
        end)
    end)

    if not ok then
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
    local screen = getFocusedScreen()
    if not screen then return end

    local windows = getWindowsOnCurrentSpace(screen)
    local _, spaces = getCurrentSpaceIndex(screen)
    local multipleSpaces = spaces and #spaces > 1

    -- If no windows, hop only if multiple spaces; otherwise do nothing
    if #windows == 0 then
        if multipleSpaces then
            local preferredPosition = (direction == "next") and "first" or "last"
            hopToSpace(direction, preferredPosition)
        end
        return
    end

    -- Find current window position
    local currentWindow = hs.window.frontmostWindow()
    local currentIndex = findCurrentWindowIndex(windows, currentWindow)

    -- Determine target window
    local targetWindow = nil

    if direction == "next" then
        if not currentIndex or currentIndex >= #windows then
            -- Wrap: hop only if multiple spaces, otherwise wrap within current space
            if multipleSpaces then
                hopToSpace("next", "first")
            else
                targetWindow = windows[1]
            end
        else
            -- Move to next window
            targetWindow = windows[currentIndex + 1]
        end
    else -- "prev"
        if not currentIndex or currentIndex <= 1 then
            -- Wrap: hop only if multiple spaces, otherwise wrap within current space
            if multipleSpaces then
                hopToSpace("prev", "last")
            else
                targetWindow = windows[#windows]
            end
        else
            -- Move to previous window
            targetWindow = windows[currentIndex - 1]
        end
    end

    -- Focus target window if found
    if targetWindow and targetWindow.raise and targetWindow.focus then
        targetWindow:raise()
        targetWindow:focus()
    end
end

-- Hotkey binding
local function bindHotkeys()
    if not CONFIG then
        log("CONFIG not initialized in bindHotkeys")
        return
    end

    local lockSeconds = CONFIG.lockMs / 1000

    -- Create debounced cycling functions
    local cyclePrevDebounced = debounce(lockSeconds, function()
        cycleToWindow("prev")
    end)

    local cycleNextDebounced = debounce(lockSeconds, function()
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
                cyclePrevDebounced
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
                cycleNextDebounced
            )
            if nextHotkey then
                state.hotkeys.next = nextHotkey
            end
        end
    end
end

-- Original module setup function
local function setup(config)
    -- If already configured, teardown and re-bind
    if state.configured then
        teardown()
    end

    -- Merge config with defaults
    CONFIG = config or {}
    LOG = CONFIG.debug == true

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

local function teardown()
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
            self._keys.prevMods = mods
            self._keys.prev = key
        end
        if mapping.next then
            local mods, key = table.unpack(mapping.next)
            self._keys.nextMods = mods
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
