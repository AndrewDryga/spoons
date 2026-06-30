--- === WindowQuickJump ===
---
--- Window Quick Jump — numeric/alpha badges to quickly change focus between windows
---
--- Download: [https://github.com/AndrewDryga/spoons/raw/main/WindowQuickJump.spoon.zip](https://github.com/AndrewDryga/spoons/raw/main/WindowQuickJump.spoon.zip)

local obj = {}
obj.__index = obj

-- Metadata
obj.name = "WindowQuickJump"
obj.version = "1.1.0"
obj.author = "Andrew Dryga"
obj.homepage = "https://github.com/AndrewDryga/spoons"
obj.license = "MIT - https://opensource.org/licenses/MIT"

---@diagnostic disable-next-line: undefined-global, lowercase-global
hs = hs or {}

-- Logger
obj.logger = hs.logger.new('WindowQuickJump')

-- Constants
local ESCAPE_KEYCODE = 53
local MIN_WINDOW_SIZE = 8      -- ignore tiny utility/HUD windows (px)
local POSITION_TOLERANCE = 10  -- X band width (px) for left-to-right column grouping
local RETRY_DELAY = 0.12       -- s, retry once when no windows are found yet (still loading)
local DISMISS_TIMEOUT = 5      -- s, auto-dismiss the overlay so it can never get stuck

-- Badge geometry
local BADGE_GAP = 6
local PILL_EXTRA_HEIGHT = 12
local PILL_TITLE_PADDING = 14
local PILL_RADIUS = 10
local CHIP_EXTRA_WIDTH = 2
local MIN_TITLE_WIDTH = 40
local TEXT_FRAME_PADDING = 2

-- Default configuration. Users override these via the public `obj.<name>` fields
-- (see the bottom of this file); they are read into `config` at :start().
local DEFAULTS = {
    maxWindows = 35, -- maximum number of windows to badge
    badge = {
        size = 28,
        fontSize = 15,
        titleMaxW = 440,
        textYOffset = -2,
        padding = 6,
    },
    keys = {
        mod = {},
        num = "f20",
    },
}

-- Resolved configuration snapshot, taken from the public fields at :start().
local config = nil

-- Runtime state
local state = {
    hotkey = nil,
    tap = nil,
    canvases = {},
    numActive = false,
    allowRetry = true,    -- allow one retry when the window list isn't ready yet
    retryTimer = nil,     -- pending retry timer (tracked so :stop() can cancel it)
    dismissTimer = nil,   -- safety auto-dismiss timer (tracked for cancellation)
    configured = false,
}

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

-- Diagnostics go through obj.logger so its level controls visibility. Enable with
-- `spoon.WindowQuickJump.debug = true` or `spoon.WindowQuickJump.logger.level = "debug"`.
local function log(...)
    local logger = obj.logger
    if logger and logger.d then
        logger.d(...)
    end
end

local function num(value, default)
    return type(value) == "number" and value or default
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

local function safeDelete(object)
    if object and type(object.delete) == "function" then
        pcall(object.delete, object)
    end
end

local function safeStop(object)
    if object and type(object.stop) == "function" then
        pcall(object.stop, object)
    end
end

local function cancelTimer(timer)
    if timer then pcall(function() timer:stop() end) end
    return nil
end

--------------------------------------------------------------------------------
-- Text measurement (cached per pass)
--------------------------------------------------------------------------------

-- Cache keyed by font+size+text. Cleared at the start of each enterNumberMode so
-- it stays bounded, while still de-duplicating the repeated getTextDrawingSize
-- calls a single overlay pass makes (e.g. ellipsize search + the final measure).
local measureCache = {}

local function measureText(text, fontSize, font)
    local fontName = font or ".AppleSystemUIFont"
    local key = fontName .. "\0" .. tostring(fontSize) .. "\0" .. (text or "")
    local cached = measureCache[key]
    if cached then return cached end

    local size = hs.drawing.getTextDrawingSize(text, { font = fontName, size = fontSize })
    local result = { w = math.ceil(size.w), h = math.ceil(size.h) }
    measureCache[key] = result
    return result
end

local function ellipsizeText(text, maxWidth, fontSize)
    if not text or text == "" then
        return ""
    end

    if measureText(text, fontSize).w <= maxWidth then
        return text
    end

    local ellipsis = "…"
    local low, high = 1, #text
    local bestFit = ""

    while low <= high do
        local mid = math.floor((low + high) / 2)
        local candidate = text:sub(1, mid) .. ellipsis
        if measureText(candidate, fontSize).w <= maxWidth then
            bestFit = candidate
            low = mid + 1
        else
            high = mid - 1
        end
    end

    return bestFit ~= "" and bestFit or ellipsis
end

--------------------------------------------------------------------------------
-- Window enumeration and ordering
--------------------------------------------------------------------------------

local function isValidWindow(w)
    if not w then return false end
    if not (w:isVisible() and w:isStandard() and not w:isMinimized()) then
        return false
    end

    local app = w:application()
    if app and app:isHidden() then
        return false
    end

    local frame = w:frame()
    return frame and frame.w >= MIN_WINDOW_SIZE and frame.h >= MIN_WINDOW_SIZE
end

local function getWindowTitle(w)
    if not w then return "Window" end

    local app = w:application()
    local appName = app and app:name() or ""
    local title = w:title() or ""

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
-- Badge rendering
--------------------------------------------------------------------------------

local function indexToChar(index)
    if index <= 9 then
        return tostring(index)
    end
    -- A=10, B=11, C=12, ...
    return string.char(string.byte('A') + index - 10)
end

local function getColorPalette()
    local isDarkMode = (hs.host.interfaceStyle() == "Dark")

    if isDarkMode then
        return {
            pillBg        = { red = 0.13, green = 0.13, blue = 0.14, alpha = 0.90 },
            numBg         = { red = 1.00, green = 0.78, blue = 0.16, alpha = 0.98 },
            numText       = { white = 0, alpha = 1.0 },
            title         = { white = 1, alpha = 0.98 },
            activePillBg  = { red = 0.18, green = 0.55, blue = 0.98, alpha = 0.95 },
            activeNumBg   = { white = 1, alpha = 1.0 },
            activeNumText = { black = 0, alpha = 1.0 },
        }
    else
        return {
            pillBg        = { white = 0, alpha = 0.60 },
            numBg         = { black = 0, alpha = 0.92 },
            numText       = { white = 1, alpha = 1.0 },
            title         = { white = 1, alpha = 1.0 },
            activePillBg  = { red = 0.0, green = 0.48, blue = 1.0, alpha = 0.85 },
            activeNumBg   = { black = 0, alpha = 0.92 },
            activeNumText = { white = 1, alpha = 1.0 },
        }
    end
end

local function doRectsOverlap(rect1, rect2)
    return not (rect1.x > rect2.x + rect2.w or
        rect1.x + rect1.w < rect2.x or
        rect1.y > rect2.y + rect2.h or
        rect1.y + rect1.h < rect2.y)
end

local function findNonOverlappingPosition(badgeFrame, existingFrames, padding)
    local adjusted = { x = badgeFrame.x, y = badgeFrame.y, w = badgeFrame.w, h = badgeFrame.h }

    local foundOverlap = true
    while foundOverlap do
        foundOverlap = false
        for _, existingFrame in ipairs(existingFrames) do
            if doRectsOverlap(adjusted, existingFrame) then
                adjusted.y = existingFrame.y + existingFrame.h + padding
                foundOverlap = true
                break
            end
        end
    end

    return adjusted
end

local function createBadge(window, index, palette, isActive, existingFrames)
    local badge = config and config.badge
    if not badge then
        log("Warning: config not initialized in createBadge")
        return nil
    end
    if not window then
        log("Warning: createBadge called with nil window")
        return nil
    end

    local windowFrame = window:frame()
    if not windowFrame then
        log("Warning: window has no frame")
        return nil
    end

    local chipWidth = badge.size
    local padding = badge.padding
    local fontSize = badge.fontSize
    local maxTitleWidth = badge.titleMaxW
    local textYOffset = badge.textYOffset

    local badgeChar = indexToChar(index)
    local windowTitle = getWindowTitle(window)
    local truncatedTitle = ellipsizeText(windowTitle, maxTitleWidth, fontSize)

    local pillHeight = math.max(chipWidth, fontSize + PILL_EXTRA_HEIGHT)
    local titleWidth = math.max(MIN_TITLE_WIDTH, measureText(truncatedTitle, fontSize).w)
    local pillWidth = chipWidth + BADGE_GAP + titleWidth + PILL_TITLE_PADDING
    local textMidY = math.floor((pillHeight - fontSize) / 2) + textYOffset

    local badgeFrame = {
        x = windowFrame.x + padding,
        y = windowFrame.y + padding,
        w = pillWidth,
        h = pillHeight,
    }
    badgeFrame = findNonOverlappingPosition(badgeFrame, existingFrames, padding)

    local canvas = hs.canvas.new(badgeFrame)
    canvas:level(hs.canvas.windowLevels.overlay)
    canvas:alpha(1.0)

    local colors = {
        pill = isActive and palette.activePillBg or palette.pillBg,
        numBg = isActive and palette.activeNumBg or palette.numBg,
        numText = isActive and palette.activeNumText or palette.numText,
        title = palette.title,
    }

    -- pill background
    canvas:appendElements({
        type = "rectangle",
        action = "fill",
        fillColor = colors.pill,
        roundedRectRadii = { xRadius = PILL_RADIUS, yRadius = PILL_RADIUS },
        frame = { x = 0, y = 0, w = pillWidth, h = pillHeight },
    })
    -- number chip background
    canvas:appendElements({
        type = "rectangle",
        action = "fill",
        fillColor = colors.numBg,
        roundedRectRadii = { xRadius = PILL_RADIUS, yRadius = PILL_RADIUS },
        frame = { x = 0, y = 0, w = chipWidth + CHIP_EXTRA_WIDTH, h = pillHeight },
    })
    -- badge number/letter
    canvas:appendElements({
        type = "text",
        text = badgeChar,
        textFont = ".AppleSystemUIFontBold",
        textSize = fontSize,
        textColor = colors.numText,
        textAlignment = "center",
        frame = { x = 0, y = textMidY, w = chipWidth, h = fontSize + TEXT_FRAME_PADDING },
    })
    -- window title
    canvas:appendElements({
        type = "text",
        text = truncatedTitle,
        textFont = ".AppleSystemUIFont",
        textSize = fontSize,
        textColor = colors.title,
        textAlignment = "left",
        frame = {
            x = chipWidth + BADGE_GAP + TEXT_FRAME_PADDING,
            y = textMidY,
            w = titleWidth,
            h = fontSize + TEXT_FRAME_PADDING,
        },
    })

    canvas:show()
    table.insert(existingFrames, badgeFrame)
    return canvas
end

--------------------------------------------------------------------------------
-- Number mode (overlay + key capture)
--------------------------------------------------------------------------------

local function exitNumberMode()
    log("Exiting number mode")

    state.retryTimer = cancelTimer(state.retryTimer)
    state.dismissTimer = cancelTimer(state.dismissTimer)

    safeStop(state.tap)
    state.tap = nil

    for _, canvas in ipairs(state.canvases) do
        safeDelete(canvas)
    end
    state.canvases = {}

    state.numActive = false
end

local function enterNumberMode()
    log("Entering number mode")
    measureCache = {} -- bound the cache to a single pass

    local screen = getFocusedScreen()
    local windows = getWindowsOnCurrentSpace(screen)
    local maxWindows = (config and config.maxWindows) or DEFAULTS.maxWindows
    local count = math.min(maxWindows, #windows)

    if count == 0 then
        -- Retry once in case windows are still loading after a Space switch.
        if state.allowRetry then
            state.allowRetry = false
            exitNumberMode()
            state.retryTimer = hs.timer.doAfter(RETRY_DELAY, enterNumberMode)
            return
        end
        log("No windows to label")
        exitNumberMode()
        return
    end

    state.allowRetry = true
    state.numActive = true

    local palette = getColorPalette()
    local focusedWindow = hs.window.focusedWindow()
    local focusedWindowId = focusedWindow and focusedWindow:id()
    local drawnFrames = {}

    -- Draw badges and build the key -> window map in one pass.
    state.canvases = {}
    local keyMapping = {}
    for i = 1, count do
        local window = windows[i]
        if window then
            local isActive = (focusedWindowId and window:id() == focusedWindowId) or false
            local badge = createBadge(window, i, palette, isActive, drawnFrames)
            if badge then
                table.insert(state.canvases, badge)
            end
            keyMapping[string.lower(indexToChar(i))] = window
        end
    end

    -- Capture the next keystroke. The tap is listen-through (returns false) for
    -- keys we don't handle, except that any printable non-badge key dismisses the
    -- overlay so it can't sit there swallowing badge keys.
    state.tap = hs.eventtap.new({ hs.eventtap.event.types.keyDown }, function(event)
        if event:getKeyCode() == ESCAPE_KEYCODE then
            exitNumberMode()
            return true
        end

        local chars = event:getCharacters()
        if not chars or chars == "" then
            return false -- modifier-only / non-printable: keep the overlay up
        end

        local targetWindow = keyMapping[string.lower(chars)]
        if targetWindow then
            exitNumberMode()
            if isValidWindow(targetWindow) then
                pcall(function() targetWindow:focus() end) -- focus() also raises
            end
            return true
        end

        -- Any other printable key cancels the overlay (and passes through).
        exitNumberMode()
        return false
    end)

    -- Abort cleanly if the tap can't actually run (e.g. Accessibility revoked),
    -- so we never leave an overlay up with no way to dismiss it.
    local started = state.tap ~= nil and pcall(function() state.tap:start() end)
    if started and state.tap.isEnabled then
        started = state.tap:isEnabled()
    end
    if not started then
        log("Event tap failed to start; aborting number mode")
        exitNumberMode()
        return
    end

    -- Safety net: auto-dismiss after a while so the overlay can't get stuck even
    -- if the tap is silently disabled by the OS mid-session.
    state.dismissTimer = hs.timer.doAfter(DISMISS_TIMEOUT, exitNumberMode)
end

-- Bind the toggle hotkey.
local function bindHotkeys()
    state.hotkey = hs.hotkey.bind(config.keys.mod, config.keys.num, function()
        if state.numActive then
            exitNumberMode()
        else
            enterNumberMode()
        end
    end)
end

--------------------------------------------------------------------------------
-- Spoon API
--------------------------------------------------------------------------------

function obj:init()
    return self
end

function obj:start()
    if state.configured then self:stop() end -- re-bind cleanly on reconfigure

    local keys = self._keys or {}
    config = {
        debug = self.debug == true,
        maxWindows = num(self.maxWindows, DEFAULTS.maxWindows),
        badge = {
            size = num(self.badgeSize, DEFAULTS.badge.size),
            fontSize = num(self.badgeFontSize, DEFAULTS.badge.fontSize),
            titleMaxW = num(self.titleMaxWidth, DEFAULTS.badge.titleMaxW),
            textYOffset = num(self.textYOffset, DEFAULTS.badge.textYOffset),
            padding = num(self.badgePadding, DEFAULTS.badge.padding),
        },
        keys = {
            mod = keys.mod or DEFAULTS.keys.mod,
            num = keys.num or DEFAULTS.keys.num,
        },
    }

    -- Honor `spoon.WindowQuickJump.debug = true` (the logger.level setter works too).
    if config.debug then
        pcall(function() obj.logger.setLogLevel('debug') end)
    end

    bindHotkeys()
    state.configured = true
    log("Started")
    return self
end

function obj:stop()
    exitNumberMode() -- cancels timers, stops the tap, deletes canvases
    safeDelete(state.hotkey)
    state.hotkey = nil
    state.allowRetry = true
    state.configured = false
    log("Stopped")
    return self
end

function obj:bindHotkeys(mapping)
    if mapping and mapping.toggle then
        local mods, key = table.unpack(mapping.toggle)
        self._keys = { mod = normalizeMods(mods), num = key }
    end
    return self
end

-- Public configuration (set these on the spoon before calling :start())
obj.debug = false
obj.maxWindows = DEFAULTS.maxWindows
obj.badgeSize = DEFAULTS.badge.size
obj.badgeFontSize = DEFAULTS.badge.fontSize
obj.titleMaxWidth = DEFAULTS.badge.titleMaxW
obj.textYOffset = DEFAULTS.badge.textYOffset
obj.badgePadding = DEFAULTS.badge.padding

return obj
