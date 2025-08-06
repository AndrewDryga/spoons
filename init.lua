-- =========================================
--  Cross-Display Window/Space Cycler (no UI)
--  F19: next  |  F18: prev
--  - List = all visible windows on the current Spaces (one per display), across ALL screens.
--  - Order = top→bottom, then left→right (global coords).
--  - Wrap edges by sending macOS Ctrl+→/← on the focused window's display only.
--  F20: show 1..9 badges (same order/indices); press digit to jump; any other key cancels.
--  Logs: set LOG=true below.
-- =========================================

-------------------
-- Config / Logs --
-------------------
local LOG           = true -- set to true to print detailed logs
local LOCK_MS       = 220
local STEP_DELAY_S  = 0.12 -- delay between Ctrl+Arrow steps
local BADGE_SIZE    = 28   -- height of the left number chip
local FONT_SIZE     = 15
local TITLE_MAX_W   = 440
local TEXT_Y_OFFSET = -2   -- nudge text up by 2px
local PADDING       = 6    -- a little tighter
local SAFE_CLICK    = true -- click desktop to give a display keyboard focus before Ctrl+Arrows

local function log(...) if LOG then print("[cycle]", ...) end end

------------------------
-- Helpers & Filters  --
------------------------
local function good(w)
    return w
        and w:isStandard()
        and not w:isMinimized()
        and not (w:application() and w:application():isHidden())
end

local function sortYthenX(wins)
    table.sort(wins, function(a, b)
        local fa, fb = a:frame(), b:frame()
        if fa.y ~= fb.y then return fa.y < fb.y end
        if fa.x ~= fb.x then return fa.x < fb.x end
        return a:id() < b:id()
    end)
    return wins
end

local function focusedScreen()
    local fw = hs.window.frontmostWindow()
    local sc = (fw and fw:screen()) or hs.screen.mainScreen()
    return sc
end

-- All *visible* windows on the current Spaces (one per display), across ALL screens
local function windowsOnCurrentSpaces_AllScreens()
    local wf = hs.window.filter.defaultCurrentSpace
    local out = {}
    for _, w in ipairs(wf:getWindows()) do
        if good(w) then out[#out + 1] = w end
    end
    return sortYthenX(out)
end

--------------------------
-- Per-display space hop --
--------------------------
local function activateDisplay(scr)
    if not SAFE_CLICK then return end
    local f = scr:fullFrame()
    local before = hs.mouse.absolutePosition()
    local pt = { x = math.floor(f.x + f.w / 2), y = math.floor(f.y + f.h - 24) }
    hs.mouse.absolutePosition(pt)
    hs.eventtap.leftClick(pt, 0)
    hs.mouse.absolutePosition(before)
    hs.timer.usleep(50 * 1000)
    log("Activated display", scr:getUUID())
end

local function stepSpace(scr, dir) -- "left" or "right"
    activateDisplay(scr)
    hs.eventtap.keyStroke({ "ctrl" }, dir, 0)
    hs.timer.usleep(STEP_DELAY_S * 1e6)
    log("Ctrl+" .. (dir == "right" and "→" or "←"), "on display", scr:getUUID())
end

-- Advance spaces on this display until we find one with at least one window (bounded by #spaces)
local function hopToSpaceWithWindows(scr, dir)
    local uuid = scr:getUUID()
    local sids = hs.spaces.allSpaces()[uuid] or {}
    if #sids == 0 then
        log("No spaces for display", uuid); return
    end
    for i = 1, #sids do
        stepSpace(scr, dir)
        local wins = windowsOnCurrentSpaces_AllScreens()
        -- We only care that the *current spaces across displays* now include something on this display.
        -- Filter to this display:
        local hasOnThisDisplay = false
        for _, w in ipairs(wins) do
            if w:screen():getUUID() == uuid then
                hasOnThisDisplay = true
                break
            end
        end
        log("After step", i, "hasOnThisDisplay=", hasOnThisDisplay)
        if hasOnThisDisplay then return end
    end
    log("Wrapped all spaces on display", uuid, "but found none with windows")
end

-------------------
-- Cycling (F18/19)
-------------------
local BUSY = false
local function withLock(fn)
    if BUSY then return end
    BUSY = true
    local ok, err = pcall(fn)
    if not ok then hs.alert.show("Error: " .. tostring(err)) end
    hs.timer.doAfter(LOCK_MS / 1000, function() BUSY = false end)
end

local function cycle(dir) -- "next" | "prev"
    withLock(function()
        local list = windowsOnCurrentSpaces_AllScreens()
        local n = #list
        if n == 0 then
            log("No windows to cycle"); return
        end

        local cur = hs.window.frontmostWindow()
        local pos = nil
        for i, w in ipairs(list) do
            if w == cur then
                pos = i
                break
            end
        end

        log("Cycle", dir, "n=", n, "currentPos=", pos, "currentSpacePerDisplay=", hs.inspect(hs.spaces.activeSpaces()))

        if dir == "next" then
            if not pos then
                log("Current not in list → focusing first"); list[1]:focus(); return
            end
            if pos < n then
                log("Focus idx", pos + 1); list[pos + 1]:focus(); return
            end

            -- end → hop next Space on *focused window's display* and focus first window there
            local scr = focusedScreen()
            log("At end; hopping next space on display", scr:getUUID())
            hopToSpaceWithWindows(scr, "right")
            local nextList = windowsOnCurrentSpaces_AllScreens()
            -- Focus first window that lives on the same display we just stepped
            for _, w in ipairs(nextList) do
                if w:screen():getUUID() == scr:getUUID() then
                    log("Focus first in next space:", w:title()); w:focus(); return
                end
            end
            log("No windows on next space for this display")
        else
            if not pos then
                log("Current not in list → focusing last"); list[#list]:focus(); return
            end
            if pos > 1 then
                log("Focus idx", pos - 1); list[pos - 1]:focus(); return
            end

            -- begin → hop prev Space on this display and focus last window there
            local scr = focusedScreen()
            log("At beginning; hopping prev space on display", scr:getUUID())
            hopToSpaceWithWindows(scr, "left")
            local prevList = windowsOnCurrentSpaces_AllScreens()
            for i = #prevList, 1, -1 do
                if prevList[i]:screen():getUUID() == scr:getUUID() then
                    log("Focus last in prev space:", prevList[i]:title()); prevList[i]:focus(); return
                end
            end
            log("No windows on prev space for this display")
        end
    end)
end

hs.hotkey.bind({}, "f19", function() cycle("next") end)
hs.hotkey.bind({}, "f18", function() cycle("prev") end)

-------------------
-- Badges (F20)  --
-------------------
local numMode = { active = false, binds = {}, badges = {}, mapping = {}, tap = nil }

local function textSize(s, size, font)
    local fnt = font or "Helvetica"
    local sz  = hs.drawing.getTextDrawingSize(s, { font = fnt, size = size })
    return { w = math.ceil(sz.w), h = math.ceil(sz.h) }
end

local function ellipsizeToWidth(s, maxW)
    if not s or s == "" then return "" end
    if textSize(s, FONT_SIZE).w <= maxW then return s end
    local ell, lo, hi, best = "…", 1, #s, ""
    while lo <= hi do
        local mid = math.floor((lo + hi) / 2)
        local cand = s:sub(1, mid) .. ell
        if textSize(cand, FONT_SIZE).w <= maxW then
            best = cand; lo = mid + 1
        else
            hi = mid - 1
        end
    end
    return best ~= "" and best or ell
end

local function palette()
    local dark = (hs.host.interfaceStyle() == "Dark")
    if dark then
        return {
            -- Capsule background + divider
            pillBg  = { red = 0.13, green = 0.13, blue = 0.14, alpha = 0.90 },
            divider = { white = 1, alpha = 0.12 },
            -- Number chip (accent) + text
            numBg   = { red = 1.00, green = 0.78, blue = 0.16, alpha = 0.98 }, -- warm amber
            numText = { white = 0, alpha = 1.0 },
            -- Title text
            title   = { white = 1, alpha = 0.98 },
        }
    else
        return {
            pillBg  = { white = 0, alpha = 0.60 },
            divider = { white = 1, alpha = 0.25 },
            numBg   = { black = 0, alpha = 0.92 },
            numText = { white = 1, alpha = 1.0 },
            title   = { white = 1, alpha = 1.0 },
        }
    end
end

-- Unified capsule badge with a left “number chip” and title; no divider seam.
local function makeBadge(win, idx, pal)
    local f      = win:frame()
    local chipW  = BADGE_SIZE -- square chip for number
    local pad    = PADDING
    local gap    = 6          -- tighter spacing
    local numStr = tostring(idx)

    -- Title (fallback to app name)
    local ttl    = win:title()
    if not ttl or #ttl == 0 then
        local app = win:application() and win:application():name() or "Window"
        ttl = app
    end

    -- Measure helpers
    local function textSize(s, size, font)
        local fnt = font or ".AppleSystemUIFont"
        local sz  = hs.drawing.getTextDrawingSize(s, { font = fnt, size = size })
        return { w = math.ceil(sz.w), h = math.ceil(sz.h) }
    end
    local function ellipsizeToWidth(s, maxW)
        if not s or s == "" then return "" end
        if textSize(s, FONT_SIZE).w <= maxW then return s end
        local ell, lo, hi, best = "…", 1, #s, ""
        while lo <= hi do
            local mid = math.floor((lo + hi) / 2)
            local cand = s:sub(1, mid) .. ell
            if textSize(cand, FONT_SIZE).w <= maxW then
                best = cand; lo = mid + 1
            else
                hi = mid - 1
            end
        end
        return best ~= "" and best or ell
    end

    ttl         = ellipsizeToWidth(ttl, TITLE_MAX_W)
    local ttlW  = math.max(40, textSize(ttl, FONT_SIZE, ".AppleSystemUIFont").w)

    local pillH = math.max(BADGE_SIZE, FONT_SIZE + 12)
    local pillW = chipW + gap + ttlW + 14
    local x     = f.x + pad
    local y     = f.y + pad
    local midY  = math.floor((pillH - FONT_SIZE) / 2) + TEXT_Y_OFFSET

    local c     = hs.canvas.new({ x = x, y = y, w = pillW, h = pillH })
    c:level(hs.canvas.windowLevels.overlay)
    c:alpha(1.0)

    -- Capsule background
    c:appendElements({
        type = "rectangle",
        action = "fill",
        fillColor = pal.pillBg,
        roundedRectRadii = { xRadius = 8, yRadius = 8 },
        frame = { x = 0, y = 0, w = pillW, h = pillH }
    })

    -- Number chip (overlap +2px to kill any seam; no divider)
    c:appendElements({
        type = "rectangle",
        action = "fill",
        fillColor = pal.numBg,
        roundedRectRadii = { xRadius = 8, yRadius = 8 },
        frame = { x = 0, y = 0, w = chipW + 2, h = pillH } -- +2px overlap removes gray edge
    })

    -- Text on top
    c:appendElements({
        type = "text",
        text = numStr,
        textFont = ".AppleSystemUIFontBold",
        textSize = FONT_SIZE,
        textColor = pal.numText,
        textAlignment = "center",
        frame = { x = 0, y = midY, w = chipW, h = FONT_SIZE + 2 }
    })
    c:appendElements({
        type = "text",
        text = ttl,
        textFont = ".AppleSystemUIFont",
        textSize = FONT_SIZE,
        textColor = pal.title,
        textAlignment = "left",
        frame = { x = chipW + gap + 2, y = midY, w = ttlW, h = FONT_SIZE + 2 }
    })

    c:show()
    return c
end

-- Build list (1..9) based on current order across ALL screens (same as F18/F19)
local function buildOrderedListAndMap()
    local list = windowsOnCurrentSpaces_AllScreens()
    local map  = {}
    for i = 1, math.min(9, #list) do map[i] = list[i] end
    log("Badge list size=", #list, "showing=", math.min(9, #list))
    return list, map
end

local numMode = { active = false, binds = {}, badges = {}, mapping = {}, tap = nil }

local function clearNumMode()
    if numMode.tap then
        numMode.tap:stop(); numMode.tap = nil
    end
    for _, b in pairs(numMode.binds) do b:delete() end
    for _, c in pairs(numMode.badges) do c:delete() end
    numMode = { active = false, binds = {}, badges = {}, mapping = {}, tap = nil }
    log("Badges cleared")
end

local function enterNumMode()
    if numMode.active then return end
    -- reset containers
    for _, b in pairs(numMode.binds) do b:delete() end
    for _, c in pairs(numMode.badges) do c:delete() end
    numMode = { active = false, binds = {}, badges = {}, mapping = {}, tap = nil }

    local list, mapping = buildOrderedListAndMap()
    local count = 0; for _ in pairs(mapping) do count = count + 1 end
    if count == 0 then
        log("No windows to label"); return
    end

    local pal = palette()
    for i = 1, count do
        local w            = mapping[i]
        numMode.mapping[i] = w
        numMode.badges[i]  = makeBadge(w, i, pal)
        numMode.binds[i]   = hs.hotkey.bind({}, tostring(i), function()
            local t = numMode.mapping[i]
            clearNumMode()
            if t then t:focus() end
        end)
    end

    -- Any non-digit cancels
    numMode.tap = hs.eventtap.new({ hs.eventtap.event.types.keyDown }, function(evt)
        local ch = evt:getCharacters(true) or ""
        if ch:match("^[1-9]$") then return false end
        clearNumMode()
        return false
    end)
    numMode.tap:start()

    numMode.active = true
    log("Badges shown; digits active 1.." .. tostring(count))
end

hs.hotkey.bind({}, "f20", function()
    if numMode.active then clearNumMode() else enterNumMode() end
end)

-- Hotkeys for cycling
hs.hotkey.bind({}, "f19", function() cycle("next") end)
hs.hotkey.bind({}, "f18", function() cycle("prev") end)
