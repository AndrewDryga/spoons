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
--   config.hopSettle   : number  (unused here, but fine if present)
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
    if LOG then print("[window_quick_jump]", ...) end
end

-- Helpers & Filters

local function good(w)
    if not (w and w:isVisible() and w:isStandard() and not w:isMinimized()) then return false end
    local app = w:application()
    if app and app:isHidden() then return false end
    local f = w:frame()
    return f and f.w >= 8 and f.h >= 8
end

local function safeTitle(w)
    local appName = (w and w:application() and w:application():name()) or ""
    local title   = (w and w:title()) or ""

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

local function sortXthenY(wins)
    table.sort(wins, function(a, b)
        local fa, fb = a:frame(), b:frame()
        if math.abs(fa.x - fb.x) > 10 then return fa.x < fb.x end
        if fa.y ~= fb.y then return fa.y < fb.y end
        return a:id() < b:id()
    end)
    return wins
end

local function focusedScreen()
    local fw = hs.window.frontmostWindow()
    return (fw and fw:screen()) or hs.screen.mainScreen()
end

local wf_current = hs.window.filter.defaultCurrentSpace
local function windowsOnCurrent(scr)
    local out = {}
    for _, w in ipairs((wf_current and wf_current.getWindows and wf_current:getWindows()) or {}) do
        if (w and w.screen and w:screen() and w:screen().id and scr and scr.id and w:screen():id() == scr:id() and good(w)) then
            table.insert(out, w)
        end
    end
    return sortXthenY(out)
end

local function indexToChar(i)
    if i <= 9 then
        return tostring(i)
    else
        return string.char(string.byte('A') + i - 10)
    end
end

local function textSize(s, size, font)
    local fnt = font or ".AppleSystemUIFont"
    local sz  = hs.drawing.getTextDrawingSize(s, { font = fnt, size = size })
    return { w = math.ceil(sz.w), h = math.ceil(sz.h) }
end

local function ellipsizeToWidth(s, maxW)
    if not s or s == "" then return "" end
    if textSize(s, ((CONFIG and CONFIG.badge and CONFIG.badge.fontSize) or 15)).w <= maxW then return s end
    local ell, lo, hi, best = "…", 1, #s, ""
    while lo <= hi do
        local mid = math.floor((lo + hi) / 2)
        local cand = s:sub(1, mid) .. ell
        if textSize(cand, ((CONFIG and CONFIG.badge and CONFIG.badge.fontSize) or 15)).w <= maxW then
            best = cand; lo = mid + 1
        else
            hi = mid - 1
        end
    end
    return (best ~= "" and best) or ell
end

local function palette()
    local dark = (hs.host.interfaceStyle() == "Dark")
    if dark then
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

local function rectsOverlap(f1, f2)
    return not (f1.x > f2.x + f2.w or
        f1.x + f1.w < f2.x or
        f1.y > f2.y + f2.h or
        f1.y + f1.h < f2.y)
end

local function makeBadge(win, idx, pal, isActive, existingFrames)
    local f          = (win and win.frame and win:frame()) or { x = 0, y = 0, w = 100, h = 80 }
    local chipW      = ((CONFIG and CONFIG.badge and CONFIG.badge.size) or 28)
    local pad        = ((CONFIG and CONFIG.badge and CONFIG.badge.padding) or 6)
    local gap        = 6
    local numStr     = indexToChar(idx)
    local ttl        = ellipsizeToWidth(safeTitle(win), ((CONFIG and CONFIG.badge and CONFIG.badge.titleMaxW) or 440))

    local pillH      = math.max(((CONFIG and CONFIG.badge and CONFIG.badge.size) or 28),
        (((CONFIG and CONFIG.badge and CONFIG.badge.fontSize) or 15) + 12))
    local titleW     = math.max(40, textSize(ttl, ((CONFIG and CONFIG.badge and CONFIG.badge.fontSize) or 15)).w)
    local pillW      = chipW + gap + titleW + 14
    local midY       = math.floor((pillH - ((CONFIG and CONFIG.badge and CONFIG.badge.fontSize) or 15)) / 2) +
        ((CONFIG and CONFIG.badge and CONFIG.badge.textYOffset) or -2)

    local badgeFrame = { x = f.x + pad, y = f.y + pad, w = pillW, h = pillH }

    -- De-conflict with existing badges
    local wasMoved   = true
    while wasMoved do
        wasMoved = false
        for _, otherFrame in ipairs(existingFrames) do
            if rectsOverlap(badgeFrame, otherFrame) then
                badgeFrame.y = otherFrame.y + otherFrame.h + pad
                wasMoved = true
                break
            end
        end
    end

    local c = hs.canvas.new(badgeFrame)
    c:level(hs.canvas.windowLevels.overlay); c:alpha(1.0)

    local pillBgColor  = isActive and pal.activePillBg or pal.pillBg
    local numBgColor   = isActive and pal.activeNumBg or pal.numBg
    local numTextColor = isActive and pal.activeNumText or pal.numText
    local titleColor   = pal.title

    c:appendElements({
        type = "rectangle",
        action = "fill",
        fillColor = pillBgColor,
        roundedRectRadii = { xRadius = 10, yRadius = 10 },
        frame = { x = 0, y = 0, w = pillW, h = pillH }
    })
    c:appendElements({
        type = "rectangle",
        action = "fill",
        fillColor = numBgColor,
        roundedRectRadii = { xRadius = 10, yRadius = 10 },
        frame = { x = 0, y = 0, w = chipW + 2, h = pillH }
    })
    c:appendElements({
        type = "text",
        text = numStr,
        textFont = ".AppleSystemUIFontBold",
        textSize = ((CONFIG and CONFIG.badge and CONFIG.badge.fontSize) or 15),
        textColor = numTextColor,
        textAlignment = "center",
        frame = { x = 0, y = midY, w = chipW, h = ((CONFIG and CONFIG.badge and CONFIG.badge.fontSize) or 15) + 2 }
    })
    c:appendElements({
        type = "text",
        text = ttl,
        textFont = ".AppleSystemUIFont",
        textSize = ((CONFIG and CONFIG.badge and CONFIG.badge.fontSize) or 15),
        textColor = titleColor,
        textAlignment = "left",
        frame = { x = chipW + gap + 2, y = midY, w = titleW, h = ((CONFIG and CONFIG.badge and CONFIG.badge.fontSize) or 15) + 2 }
    })

    c:show()
    existingFrames[#existingFrames + 1] = badgeFrame
    return c, badgeFrame
end

local function buildBadgeList()
    local scr  = focusedScreen()
    local list = windowsOnCurrent(scr)
    return list
end

local function exit_number_mode()
    log("exited number mode")
    if state.tap then
        pcall(function()
            local tap = state.tap
            if tap and tap.stop then tap:stop() end
        end)
        state.tap = nil
    end
    for _, c in ipairs(state.canvases) do
        pcall(function() c:delete() end)
    end
    state.canvases = {}
    state.numActive = false
end

local function enter_number_mode()
    log("entered number mode")

    local list = buildBadgeList()
    local count = math.min(((CONFIG and CONFIG.maxBadges) or 35), #list or 0)
    if count == 0 then
        if state.firstBadgeRetry then
            state.firstBadgeRetry = false
            exit_number_mode()
            hs.timer.doAfter(0.12, function() enter_number_mode() end)
            return
        else
            log("No windows to label")
            exit_number_mode()
            return
        end
    end

    state.firstBadgeRetry = true
    state.numActive = true
    local pal = palette()
    local currentWin = hs.window.focusedWindow()
    local drawnFrames = {}
    state.canvases = {}

    -- Draw badges in order
    for i = 1, count do
        local w = list[i]
        local isActive = (currentWin and w and w:id() == currentWin:id())
        local badgeCanvas = select(1, makeBadge(w, i, pal, isActive, drawnFrames))
        state.canvases[#state.canvases + 1] = badgeCanvas
    end

    -- Build key mapping
    local keyMapping = {}
    for i = 1, count do
        local char = string.lower(indexToChar(i))
        keyMapping[char] = list[i]
    end

    -- Event tap for number/letter keys and Escape
    state.tap = hs.eventtap.new({ hs.eventtap.event.types.keyDown }, function(e)
        -- Escape
        if e:getKeyCode() == 53 then
            exit_number_mode()
            return true
        end

        local chars = e:getCharacters()
        if not chars then return false end
        local key = string.lower(chars)
        local win = keyMapping[key]

        if win then
            exit_number_mode()
            win:raise(); win:focus()
            return true
        end

        return false -- allow other keys to pass
    end)
    if state.tap then
        pcall(function()
            local t = state.tap
            if t and t.start then t:start() end
        end)
    end
end

-- Public API

function M.setup(config)
    if state.configured then M.teardown() end

    CONFIG                   = config or {}
    LOG                      = not not (CONFIG and CONFIG.debug)

    CONFIG.maxBadges         = CONFIG.maxBadges or 35
    CONFIG.badge             = CONFIG.badge or {}
    CONFIG.badge.size        = CONFIG.badge.size or 28
    CONFIG.badge.fontSize    = CONFIG.badge.fontSize or 15
    CONFIG.badge.titleMaxW   = CONFIG.badge.titleMaxW or 440
    CONFIG.badge.textYOffset = (CONFIG.badge.textYOffset ~= nil) and CONFIG.badge.textYOffset or -2
    CONFIG.badge.padding     = CONFIG.badge.padding or 6

    CONFIG.keys              = CONFIG.keys or {}
    CONFIG.keys.mod          = CONFIG.keys.mod or {}
    CONFIG.keys.num          = CONFIG.keys.num or "f20"

    state.hotkey             = hs.hotkey.bind(CONFIG.keys.mod, CONFIG.keys.num, function()
        if state.numActive then
            exit_number_mode()
        else
            enter_number_mode()
        end
    end)

    state.configured         = true
    log("window_quick_jump: setup complete")
end

function M.teardown()
    if state.hotkey then
        pcall(function()
            local hk = state.hotkey
            if hk and hk.delete then hk:delete() end
        end)
    end
    state.hotkey = nil

    exit_number_mode()

    state.configured = false
    log("window_quick_jump: teardown complete")
end

return M
