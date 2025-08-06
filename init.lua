-- =========================================
--  Window/Space Cycler — Snappy (optimistic hop, no confirmation wait)
--  F18: prev   |   F19: next   |   F20: badges 1..9
--  - Per focused display & Space; window order: top→bottom, left→right
--  - Hop order: AppleScript key-down/up (fast) → Eventtap fallback (one-shot)
--  - No “did it change?” polling; we assume hop succeeded and schedule a quick focus
--  - Ignores minimized / hidden / non-standard / tiny windows
-- =========================================

-------------------
-- Config / Logs --
-------------------
local LOG           = true
local LOCK_MS       = 70         -- shorter debounce for faster repeated taps
local HOP_SETTLE_MS = 0.16       -- delay before focusing a window in the *new* space
local AS_KD_DELAY   = 0.010
local AS_KU_DELAY   = 0.005
local ET_RELEASE_US = 1200       -- eventtap key up after this many µs
local BADGE_SIZE    = 28
local FONT_SIZE     = 15
local TITLE_MAX_W   = 440
local TEXT_Y_OFFSET = -2
local PADDING       = 6

local function log(...) if LOG then print("[cycle]", ...) end end

------------------------
-- Helpers & Filters  --
------------------------
local function good(w)
    if not (w and w:isVisible() and w:isStandard() and not w:isMinimized()) then return false end
    local app = w:application()
    if app and app:isHidden() then return false end
    local f = w:frame()
    if not f or f.w < 8 or f.h < 8 then return false end
    return true
end

local function safeTitle(w)
    local t = (w and w:title()) or ""
    if t and #t > 0 then return t end
    return (w and w:application() and w:application():name()) or "Window"
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
    return (fw and fw:screen()) or hs.screen.mainScreen()
end

-- Windows visible on current Space for a given screen (no hs.spaces)
local wf_current = hs.window.filter.defaultCurrentSpace
local function windowsOnCurrentSpaceForScreen(scr)
    local out = {}
    for _, w in ipairs(wf_current:getWindows()) do
        if w and w:screen():id() == scr:id() and good(w) then out[#out + 1] = w end
    end
    return sortYthenX(out)
end

--------------------------
-- Fast hop primitives  --
--------------------------
-- 1) AppleScript: key down ctrl → keycode ←/→ → key up ctrl
local function hop_AS(dir)
    local code = (dir == "right") and 124 or 123
    local script = ([[
    tell application "System Events"
      key down control
      delay %f
      key code %d
      delay %f
      key up control
    end tell
  ]]):format(AS_KD_DELAY, code, AS_KU_DELAY)
    local ok, err = hs.osascript.applescript(script)
    if not ok and err then log("AS err:", err) end
end

-- 2) Eventtap fallback: one non-autorepeat chord
local function hop_ET(dir)
    local key = (dir == "right") and "right" or "left"
    local evd = hs.eventtap.event.newKeyEvent({ "ctrl" }, key, true)
    local evu = hs.eventtap.event.newKeyEvent({ "ctrl" }, key, false)
    evd:setProperty(hs.eventtap.event.properties.keyboardEventAutorepeat, 0)
    evu:setProperty(hs.eventtap.event.properties.keyboardEventAutorepeat, 0)
    evd:post(); hs.timer.usleep(ET_RELEASE_US); evu:post()
end

-- Fire both paths quickly (AS → ET), then schedule a focus in the new space
local function hopAndFocus(scr, dir, which) -- which: "first"|"last"
    -- Fire AS; if macOS occasionally ignores it, ET covers it a few hundred µs later.
    hop_AS(dir)
    hop_ET(dir)

    hs.timer.doAfter(HOP_SETTLE_MS, function()
        local wins = windowsOnCurrentSpaceForScreen(scr)
        if #wins == 0 then return end
        local t = (which == "first") and wins[1] or wins[#wins]
        if t then
            t:raise(); t:focus()
        end
    end)
end

-------------------
-- Cycling (F18/19)
-------------------
local BUSY = false
local function withLock(fn)
    if BUSY then return end; BUSY = true
    local ok, err = pcall(fn); if not ok then hs.alert.show("Error: " .. tostring(err)) end
    hs.timer.doAfter(LOCK_MS / 1000, function() BUSY = false end)
end

local function cycle(dir) -- "next" | "prev"
    withLock(function()
        local scr  = focusedScreen()
        local list = windowsOnCurrentSpaceForScreen(scr)
        local n    = #list
        log("Cycle", dir, "display=", scr:getUUID(), "wins=", n)

        if n == 0 then
            hopAndFocus(scr, (dir == "next") and "right" or "left", (dir == "next") and "first" or "last")
            return
        end

        local cur = hs.window.frontmostWindow()
        local pos = nil; for i, w in ipairs(list) do if w == cur then
                pos = i
                break
            end end
        log("CurrentPos =", pos)

        if dir == "next" then
            if not pos or pos >= n then
                hopAndFocus(scr, "right", "first")
            else
                local t = list[pos + 1]; t:raise(); t:focus()
            end
        else
            if not pos or pos <= 1 then
                hopAndFocus(scr, "left", "last")
            else
                local t = list[pos - 1]; t:raise(); t:focus()
            end
        end
    end)
end

hs.hotkey.bind({}, "f19", function() cycle("next") end)
hs.hotkey.bind({}, "f18", function() cycle("prev") end)

-------------------
-- Badges (F20)  --
-------------------
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
        else hi = mid - 1 end
    end
    return (best ~= "" and best) or ell
end

local function palette()
    local dark = (hs.host.interfaceStyle() == "Dark")
    if dark then
        return {
            pillBg  = { red = 0.13, green = 0.13, blue = 0.14, alpha = 0.90 },
            numBg   = { red = 1.00, green = 0.78, blue = 0.16, alpha = 0.98 },
            numText = { white = 0, alpha = 1.0 },
            title   = { white = 1, alpha = 0.98 },
        }
    else
        return {
            pillBg  = { white = 0, alpha = 0.60 },
            numBg   = { black = 0, alpha = 0.92 },
            numText = { white = 1, alpha = 1.0 },
            title   = { white = 1, alpha = 1.0 },
        }
    end
end

local function makeBadge(win, idx, pal)
    local f      = win:frame()
    local chipW  = BADGE_SIZE
    local pad    = PADDING
    local gap    = 4
    local numStr = tostring(idx)
    local ttl    = ellipsizeToWidth(safeTitle(win), TITLE_MAX_W)

    local pillH  = math.max(BADGE_SIZE, FONT_SIZE + 12)
    local titleW = math.max(40, textSize(ttl, FONT_SIZE).w)
    local pillW  = chipW + gap + titleW + 14
    local x      = f.x + pad
    local y      = f.y + pad
    local midY   = math.floor((pillH - FONT_SIZE) / 2) + TEXT_Y_OFFSET

    local c      = hs.canvas.new({ x = x, y = y, w = pillW, h = pillH })
    c:level(hs.canvas.windowLevels.overlay); c:alpha(1.0)

    c:appendElements({
        type = "rectangle",
        action = "fill",
        fillColor = pal.pillBg,
        roundedRectRadii = { xRadius = 10, yRadius = 10 },
        frame = { x = 0, y = 0, w = pillW, h = pillH }
    })
    c:appendElements({
        type = "rectangle",
        action = "fill",
        fillColor = pal.numBg,
        roundedRectRadii = { xRadius = 10, yRadius = 10 },
        frame = { x = 0, y = 0, w = chipW + 2, h = pillH }
    })
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
        frame = { x = chipW + gap + 2, y = midY, w = titleW, h = FONT_SIZE + 2 }
    })

    c:show(); return c
end

local numMode = { active = false, binds = {}, badges = {}, mapping = {}, tap = nil }

local function buildOrderedListAndMap()
    local scr  = focusedScreen()
    local list = windowsOnCurrentSpaceForScreen(scr)
    local map  = {}; for i = 1, math.min(9, #list) do map[i] = list[i] end
    log("Badge list size=", #list, "showing=", math.min(9, #list))
    return list, map
end

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
    for _, b in pairs(numMode.binds) do b:delete() end
    for _, c in pairs(numMode.badges) do c:delete() end
    numMode = { active = false, binds = {}, badges = {}, mapping = {}, tap = nil }

    local _, mapping = buildOrderedListAndMap()
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
            if t then
                t:raise(); t:focus()
            end
        end)
    end

    numMode.tap = hs.eventtap.new({ hs.eventtap.event.types.keyDown }, function(evt)
        local ch = evt:getCharacters(true) or ""
        if ch:match("^[1-9]$") then return false end
        clearNumMode(); return false
    end); numMode.tap:start()

    numMode.active = true; log("Badges shown; digits active 1.." .. tostring(count))
end

hs.hotkey.bind({}, "f20", function()
    if numMode.active then clearNumMode() else enterNumMode() end
end)

-- Cycle binds
hs.hotkey.bind({}, "f19", function() cycle("next") end)
hs.hotkey.bind({}, "f18", function() cycle("prev") end)
