-- =========================================
--  Window/Space Cycler — Snappy & Production-Ready
-- =========================================

-- Configuration
local config = {
    debug     = false, -- enable verbose logging
    lockMs    = 70,    -- debounce interval for F18/F19
    hopSettle = 0.1,   -- delay before focusing on new space
    maxBadges = 35,    -- up to 9 digits + 26 letters
    keys      = {
        prev = "f18",
        next = "f19",
        num  = "f20",
    },
    badge     = {
        size        = 28,
        fontSize    = 15,
        titleMaxW   = 440,
        textYOffset = -2,
        padding     = 6,
    },
}

local LOG = config.debug

-- Debounce helper
local function debounce(interval, fn)
    local _timer = nil
    return function(...)
        local args = table.pack(...)
        if _timer then _timer:stop() end
        _timer = hs.timer.doAfter(interval, function()
            fn(table.unpack(args, 1, args.n))
        end)
    end
end
local function log(...) if LOG then print("[cycle]", ...) end end

-- Cleanup on reload
local cleanup = {}
function cleanup.reset()
    -- clear number mode tap
    if numpadTap then
        numpadTap:stop()
        numpadTap = nil
    end
    -- clear tap
    if cleanup.tap then
        cleanup.tap:stop()
        cleanup.tap = nil
    end
    -- clear hotkeys
    if cleanup.hotkeys then
        for _, hk in pairs(cleanup.hotkeys) do hk:delete() end
    end
    cleanup.hotkeys = {}
end

cleanup.reset()
cleanup.hotkeys = {}

-- Helpers & Filters
local function good(w)
    if not (w and w:isVisible() and w:isStandard() and not w:isMinimized()) then return false end
    local app = w:application()
    if app and app:isHidden() then return false end
    local f = w:frame()
    return f and f.w >= 8 and f.h >= 8
end

local function safeTitle(w)
    local t = (w and w:title()) or ""
    if #t > 0 then return t end
    return (w and w:application() and w:application():name()) or "Window"
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
    for _, w in ipairs(wf_current:getWindows()) do
        if w:screen():id() == scr:id() and good(w) then
            table.insert(out, w)
        end
    end
    return sortXthenY(out)
end

-- Space switching with pcall
local function hopAndFocus(scr, dir, which)
    local ok, err = pcall(function()
        local current = hs.spaces.focusedSpace()
        local all     = hs.spaces.allSpaces()[scr:getUUID()]
        if not all or not current then error("spaces API unavailable") end
        local idx
        for i, sid in ipairs(all) do if sid == current then idx = i end end
        if not idx then error("current space index not found") end
        local target = ((dir == "right") and (idx < #all and idx + 1 or 1))
            or ((idx > 1 and idx - 1) or #all)
        hs.spaces.gotoSpace(all[target])
        hs.timer.doAfter(config.hopSettle, function()
            local wins = windowsOnCurrent(scr)
            local w    = (which == "first" and wins[1]) or wins[#wins]
            if w then
                w:raise(); w:focus()
            end
        end)
    end)
    if not ok then log("hopAndFocus error:", err) end
end

-- Cycling (F18/F19) with debounce
local cyclePrev = debounce(config.lockMs / 1000, function()
    local scr = focusedScreen()
    local list = windowsOnCurrent(scr)
    if #list == 0 then
        hopAndFocus(scr, "left", "last"); return
    end
    local cur = hs.window.frontmostWindow()
    local pos
    for i, w in ipairs(list) do if w == cur then pos = i end end
    if not pos or pos <= 1 then
        hopAndFocus(scr, "left", "last")
    else
        local w = list[pos - 1]; w:raise(); w:focus()
    end
end)

local cycleNext = debounce(config.lockMs / 1000, function()
    local scr = focusedScreen()
    local list = windowsOnCurrent(scr)
    if #list == 0 then
        hopAndFocus(scr, "right", "first"); return
    end
    local cur = hs.window.frontmostWindow()
    local pos
    for i, w in ipairs(list) do if w == cur then pos = i end end
    if not pos or pos >= #list then
        hopAndFocus(scr, "right", "first")
    else
        local w = list[pos + 1]; w:raise(); w:focus()
    end
end)

-- Number-Mode Modal for badges
local badgeCanvases = {}
local numpadTap = nil
local numActive = false
local firstBadgeRetry = true

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
    if textSize(s, config.badge.fontSize).w <= maxW then return s end
    local ell, lo, hi, best = "…", 1, #s, ""
    while lo <= hi do
        local mid = math.floor((lo + hi) / 2)
        local cand = s:sub(1, mid) .. ell
        if textSize(cand, config.badge.fontSize).w <= maxW then
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
    local f          = win:frame()
    local chipW      = config.badge.size
    local pad        = config.badge.padding
    local gap        = 6
    local numStr     = indexToChar(idx)
    local ttl        = ellipsizeToWidth(safeTitle(win), config.badge.titleMaxW)

    local pillH      = math.max(config.badge.size, config.badge.fontSize + 12)
    local titleW     = math.max(40, textSize(ttl, config.badge.fontSize).w)
    local pillW      = chipW + gap + titleW + 14
    local midY       = math.floor((pillH - config.badge.fontSize) / 2) + config.badge.textYOffset

    local badgeFrame = { x = f.x + pad, y = f.y + pad, w = pillW, h = pillH }

    -- De-conflict with existing badges
    local wasMoved   = true
    while wasMoved do
        wasMoved = false
        for _, otherFrame in ipairs(existingFrames) do
            if rectsOverlap(badgeFrame, otherFrame) then
                badgeFrame.y = otherFrame.y + otherFrame.h + config.badge.padding
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
        textSize = config.badge.fontSize,
        textColor = numTextColor,
        textAlignment = "center",
        frame = { x = 0, y = midY, w = chipW, h = config.badge.fontSize + 2 }
    })
    c:appendElements({
        type = "text",
        text = ttl,
        textFont = ".AppleSystemUIFont",
        textSize = config.badge.fontSize,
        textColor = titleColor,
        textAlignment = "left",
        frame = { x = chipW + gap + 2, y = midY, w = titleW, h = config.badge.fontSize + 2 }
    })

    c:show()
    existingFrames[#existingFrames + 1] = badgeFrame
    return c
end

local function buildBadgeList()
    local scr  = focusedScreen()
    local list = windowsOnCurrent(scr)
    local map  = {}
    for i = 1, math.min(config.maxBadges, #list) do map[i] = list[i] end
    return list, map
end

local function exit_number_mode()
    log("exited number mode")
    if numpadTap then
        numpadTap:stop()
        numpadTap = nil
    end
    for _, c in ipairs(badgeCanvases) do c:delete() end
    badgeCanvases = {}
    numActive = false
end

local function enter_number_mode()
    log("entered number mode")

    -- build and display badges with full styling
    local list, mapping = buildBadgeList()
    local count = 0; for _ in pairs(mapping) do count = count + 1 end
    if count == 0 then
        if firstBadgeRetry then
            firstBadgeRetry = false
            exit_number_mode()
            hs.timer.doAfter(0.12, function() enter_number_mode() end)
            return
        else
            log("No windows to label"); exit_number_mode(); return
        end
    end

    firstBadgeRetry = true
    numActive = true
    local pal = palette()
    local currentWin = hs.window.focusedWindow()
    local drawnFrames = {}
    badgeCanvases = {}

    for i, w in pairs(mapping) do
        local isActive = (currentWin and w:id() == currentWin:id())
        local badgeCanvas, badgeFrame = makeBadge(w, i, pal, isActive, drawnFrames)
        badgeCanvases[#badgeCanvases + 1] = badgeCanvas
        drawnFrames[#drawnFrames + 1] = badgeFrame
    end

    -- Create event tap for number keys
    local keyMapping = {}
    for i, w in pairs(mapping) do
        local char = string.lower(indexToChar(i))
        keyMapping[char] = w
    end

    numpadTap = hs.eventtap.new({ hs.eventtap.event.types.keyDown }, function(e)
        local chars = e:getCharacters()
        if not chars then return false end
        local key = string.lower(chars)
        local win = keyMapping[key]

        if key == "escape" then
            exit_number_mode()
            return true
        elseif win then
            exit_number_mode()
            win:raise(); win:focus()
            return true
        end
        return false -- pass through other keys
    end)
    numpadTap:start()
end

-- Bind global hotkeys
cleanup.hotkeys      = cleanup.hotkeys or {}
cleanup.hotkeys.prev = hs.hotkey.bind({}, config.keys.prev, cyclePrev)
cleanup.hotkeys.next = hs.hotkey.bind({}, config.keys.next, cycleNext)
cleanup.hotkeys.num  = hs.hotkey.bind({}, config.keys.num, function()
    if numActive then
        exit_number_mode()
    else
        enter_number_mode()
    end
end)
