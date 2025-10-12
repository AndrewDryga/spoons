-- window_quick_jump.lua
-- Window Quick Jump — numeric/alpha badges to quickly change focus between windows
--
-- API:
--   local quick = require("window_quick_jump")
--   quick.setup(config)   -- binds F20 (or provided key) to toggle number mode
--   quick.teardown()      -- unbinds hotkey, removes badges, stops taps
--
-- Expected config keys (with defaults):
--   config.debug       : boolean (default: false)
--   config.maxBadges   : integer (default: 35)
--   config.keys.mod    : table   (default: {})
--   config.keys.num    : string  (default: "f20")
--   config.badge = {
--       size        = 28,
--       fontSize    = 15,
--       titleMaxW   = 440,
--       textYOffset = -2,
--       padding     = 6,
--   }

---@diagnostic disable-next-line: undefined-global, lowercase-global
hs = hs or {}

local M = {}

-- Constants
local ESCAPE_KEYCODE = 53
local MIN_WINDOW_SIZE = 8
local POSITION_TOLERANCE = 10
local RETRY_DELAY = 0.12
local BADGE_GAP = 6
local PILL_EXTRA_HEIGHT = 12
local PILL_TITLE_PADDING = 14
local PILL_RADIUS = 10
local CHIP_EXTRA_WIDTH = 2
local MIN_TITLE_WIDTH = 40
local TEXT_FRAME_PADDING = 2

-- Default configuration values
local DEFAULT_CONFIG = {
    maxBadges = 35,
    badge = {
        size = 28,
        fontSize = 15,
        titleMaxW = 440,
        textYOffset = -2,
        padding = 6,
    },
    keys = {
        mod = { "cmd" },
        num = "8",
    },
}

-- Internal state
local state = {
    hotkey = nil,
    tap = nil,
    canvases = {},
    numActive = false,
    firstBadgeRetry = true,
    configured = false,
}

-- Config provided via setup()
local CONFIG = nil
local LOG = false

local function log(...)
    if LOG then
        print("[window_quick_jump]", ...)
    end
end

-- Safe cleanup helpers
local function safeDelete(object, methodName)
    if not object then return end

    local method = object[methodName or "delete"]
    if type(method) == "function" then
        pcall(method, object)
    end
end

local function safeStop(object)
    if not object then return end

    if type(object.stop) == "function" then
        pcall(object.stop, object)
    end
end

local function safeStart(object)
    if not object then return end

    if type(object.start) == "function" then
        pcall(object.start, object)
    end
end

-- Window validation and helpers
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
        for _, window in ipairs(windowFilter:getWindows()) do
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

    return sortWindows(windows)
end

-- Badge character mapping
local function indexToChar(index)
    if index <= 9 then
        return tostring(index)
    else
        -- A=10, B=11, C=12, etc.
        return string.char(string.byte('A') + index - 10)
    end
end

-- Text measurement helpers
local function measureText(text, fontSize, font)
    local fontName = font or ".AppleSystemUIFont"
    local size = hs.drawing.getTextDrawingSize(text, {
        font = fontName,
        size = fontSize
    })
    return {
        w = math.ceil(size.w),
        h = math.ceil(size.h)
    }
end

local function ellipsizeText(text, maxWidth, fontSize)
    if not text or text == "" then
        return ""
    end

    local textSize = measureText(text, fontSize)
    if textSize.w <= maxWidth then
        return text
    end

    local ellipsis = "…"
    local low, high = 1, #text
    local bestFit = ""

    while low <= high do
        local mid = math.floor((low + high) / 2)
        local candidate = text:sub(1, mid) .. ellipsis
        local candidateSize = measureText(candidate, fontSize)

        if candidateSize.w <= maxWidth then
            bestFit = candidate
            low = mid + 1
        else
            high = mid - 1
        end
    end

    return bestFit ~= "" and bestFit or ellipsis
end

-- Color palette
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

-- Badge positioning helpers
local function doRectsOverlap(rect1, rect2)
    return not (rect1.x > rect2.x + rect2.w or
        rect1.x + rect1.w < rect2.x or
        rect1.y > rect2.y + rect2.h or
        rect1.y + rect1.h < rect2.y)
end

local function findNonOverlappingPosition(badgeFrame, existingFrames, padding)
    local adjustedFrame = {
        x = badgeFrame.x,
        y = badgeFrame.y,
        w = badgeFrame.w,
        h = badgeFrame.h
    }

    local foundOverlap = true
    while foundOverlap do
        foundOverlap = false

        for _, existingFrame in ipairs(existingFrames) do
            if doRectsOverlap(adjustedFrame, existingFrame) then
                adjustedFrame.y = existingFrame.y + existingFrame.h + padding
                foundOverlap = true
                break
            end
        end
    end

    return adjustedFrame
end

-- Badge creation
local function createBadge(window, index, palette, isActive, existingFrames)
    if not CONFIG or not CONFIG.badge then
        log("Warning: CONFIG not initialized in createBadge")
        return nil
    end

    local config = CONFIG.badge

    if not window then
        log("Warning: createBadge called with nil window")
        return nil
    end

    local windowFrame = window:frame()
    if not windowFrame then
        log("Warning: window has no frame")
        return nil
    end

    -- Badge dimensions
    local chipWidth = config.size
    local padding = config.padding
    local fontSize = config.fontSize
    local maxTitleWidth = config.titleMaxW
    local textYOffset = config.textYOffset

    -- Prepare text
    local badgeChar = indexToChar(index)
    local windowTitle = getWindowTitle(window)
    local truncatedTitle = ellipsizeText(windowTitle, maxTitleWidth, fontSize)

    -- Calculate dimensions
    local pillHeight = math.max(chipWidth, fontSize + PILL_EXTRA_HEIGHT)
    local titleWidth = math.max(MIN_TITLE_WIDTH, measureText(truncatedTitle, fontSize).w)
    local pillWidth = chipWidth + BADGE_GAP + titleWidth + PILL_TITLE_PADDING
    local textMidY = math.floor((pillHeight - fontSize) / 2) + textYOffset

    -- Initial position
    local badgeFrame = {
        x = windowFrame.x + padding,
        y = windowFrame.y + padding,
        w = pillWidth,
        h = pillHeight
    }

    -- Find non-overlapping position
    badgeFrame = findNonOverlappingPosition(badgeFrame, existingFrames, padding)

    -- Create canvas
    local canvas = hs.canvas.new(badgeFrame)
    canvas:level(hs.canvas.windowLevels.overlay)
    canvas:alpha(1.0)

    -- Select colors based on active state
    local colors = {
        pill = isActive and palette.activePillBg or palette.pillBg,
        numBg = isActive and palette.activeNumBg or palette.numBg,
        numText = isActive and palette.activeNumText or palette.numText,
        title = palette.title
    }

    -- Draw pill background
    canvas:appendElements({
        type = "rectangle",
        action = "fill",
        fillColor = colors.pill,
        roundedRectRadii = { xRadius = PILL_RADIUS, yRadius = PILL_RADIUS },
        frame = { x = 0, y = 0, w = pillWidth, h = pillHeight }
    })

    -- Draw number chip background
    canvas:appendElements({
        type = "rectangle",
        action = "fill",
        fillColor = colors.numBg,
        roundedRectRadii = { xRadius = PILL_RADIUS, yRadius = PILL_RADIUS },
        frame = { x = 0, y = 0, w = chipWidth + CHIP_EXTRA_WIDTH, h = pillHeight }
    })

    -- Draw badge number/letter
    canvas:appendElements({
        type = "text",
        text = badgeChar,
        textFont = ".AppleSystemUIFontBold",
        textSize = fontSize,
        textColor = colors.numText,
        textAlignment = "center",
        frame = { x = 0, y = textMidY, w = chipWidth, h = fontSize + TEXT_FRAME_PADDING }
    })

    -- Draw window title
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
            h = fontSize + TEXT_FRAME_PADDING
        }
    })

    canvas:show()
    table.insert(existingFrames, badgeFrame)

    return canvas
end

-- Mode management
local function exitNumberMode()
    log("Exiting number mode")

    -- Stop event tap
    safeStop(state.tap)
    state.tap = nil

    -- Delete all canvases
    for _, canvas in ipairs(state.canvases) do
        safeDelete(canvas)
    end
    state.canvases = {}

    state.numActive = false
end

local function enterNumberMode()
    log("Entering number mode")

    local screen = getFocusedScreen()
    local windows = getWindowsOnCurrentSpace(screen)
    local count = math.min((CONFIG and CONFIG.maxBadges) or DEFAULT_CONFIG.maxBadges, #windows)

    if count == 0 then
        -- Retry once in case windows are still loading
        if state.firstBadgeRetry then
            state.firstBadgeRetry = false
            exitNumberMode()
            hs.timer.doAfter(RETRY_DELAY, enterNumberMode)
            return
        else
            log("No windows to label")
            exitNumberMode()
            return
        end
    end

    state.firstBadgeRetry = true
    state.numActive = true

    local palette = getColorPalette()
    local currentWindow = hs.window.focusedWindow()
    local currentWindowId = currentWindow and currentWindow:id()
    local drawnFrames = {}

    -- Create badges for each window
    state.canvases = {}
    for i = 1, count do
        local window = windows[i]
        if window then
            local isActive = (currentWindowId and window:id() == currentWindowId)
            local badge = createBadge(window, i, palette, isActive, drawnFrames)
            if badge then
                table.insert(state.canvases, badge)
            end
        end
    end

    -- Build key mapping for quick access
    local keyMapping = {}
    for i = 1, count do
        local window = windows[i]
        if window then
            local char = string.lower(indexToChar(i))
            keyMapping[char] = window
        end
    end

    -- Setup event tap for keyboard input
    state.tap = hs.eventtap.new({ hs.eventtap.event.types.keyDown }, function(event)
        -- Check for Escape key
        if event:getKeyCode() == ESCAPE_KEYCODE then
            exitNumberMode()
            return true
        end

        -- Check for window selection keys
        local chars = event:getCharacters()
        if not chars then
            return false
        end

        local key = string.lower(chars)
        local targetWindow = keyMapping[key]

        if targetWindow then
            exitNumberMode()
            targetWindow:raise()
            targetWindow:focus()
            return true
        end

        -- Allow other keys to pass through
        return false
    end)

    safeStart(state.tap)
end

-- Public API

function M.setup(config)
    if state.configured then
        M.teardown()
    end

    -- Merge config with defaults
    CONFIG = config or {}
    LOG = CONFIG.debug == true

    -- Apply defaults for missing values
    CONFIG.maxBadges = CONFIG.maxBadges or DEFAULT_CONFIG.maxBadges

    CONFIG.badge = CONFIG.badge or {}
    CONFIG.badge.size = CONFIG.badge.size or DEFAULT_CONFIG.badge.size
    CONFIG.badge.fontSize = CONFIG.badge.fontSize or DEFAULT_CONFIG.badge.fontSize
    CONFIG.badge.titleMaxW = CONFIG.badge.titleMaxW or DEFAULT_CONFIG.badge.titleMaxW
    CONFIG.badge.textYOffset = (CONFIG.badge.textYOffset ~= nil) and CONFIG.badge.textYOffset or
        DEFAULT_CONFIG.badge.textYOffset
    CONFIG.badge.padding = CONFIG.badge.padding or DEFAULT_CONFIG.badge.padding

    CONFIG.keys = CONFIG.keys or {}
    CONFIG.keys.mod = CONFIG.keys.mod or DEFAULT_CONFIG.keys.mod
    CONFIG.keys.num = CONFIG.keys.num or DEFAULT_CONFIG.keys.num

    -- Bind hotkey
    state.hotkey = hs.hotkey.bind(CONFIG.keys.mod, CONFIG.keys.num, function()
        if state.numActive then
            exitNumberMode()
        else
            enterNumberMode()
        end
    end)

    state.configured = true
    log("Setup complete")
end

function M.teardown()
    -- Delete hotkey
    safeDelete(state.hotkey)
    state.hotkey = nil

    -- Exit number mode if active
    exitNumberMode()

    state.configured = false
    log("Teardown complete")
end

return M
