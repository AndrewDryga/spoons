--- === ShowKeyPresses ===
---
--- Keystroke visualizer for Hammerspoon. Shows keys, shortcuts, and special keys as overlay pills.
--- Uses a listen-only event tap when available, so it does not intercept your keystrokes.
---
--- Download: https://github.com/AndrewDryga/spoons/raw/main/ShowKeyPresses.spoon.zip
---
-- ShowKeyPresses.spoon — a tiny keystroke visualizer (ALL keys or shortcuts-only)
local obj          = { __gc = true }
obj.__index        = obj

---@diagnostic disable-next-line: undefined-global, lowercase-global
hs                 = hs or {}

-- Logger (kept for consistency with other Spoons; informational only)
obj.logger         = hs.logger and hs.logger.new and hs.logger.new('ShowKeyPresses') or nil

-- Spoon metadata (keep aligned with folder name)
obj.name           = "ShowKeyPresses"
obj.version        = "1.0.0"
obj.author         = "Andrew Dryga"
obj.homepage       = "https://github.com/AndrewDryga/spoons"
obj.license        = "MIT - https://opensource.org/licenses/MIT"

-- ====== CONFIG (defaults) ======
obj.cfg            = {
    -- what to show
    showText                  = true,  -- true = show all keys (typed characters). false = only shortcuts (mod+key) and specials
    showModifiersAlone        = false, -- show ⇧/⌘ press by itself
    suppressAutoRepeat        = true,  -- hide held-key repeats

    -- repeat visualization
    showRepeatCount           = true, -- show ×N when the same key is pressed repeatedly
    repeatCountWindow         = 1.0,  -- seconds to aggregate same-key presses
    repeatCountPrefix         = "×",

    -- look & placement
    position                  = "bottomcenter", -- "center" | "bottomcenter" | "topcenter"
    screenMargin              = { x = 0, y = 84 },
    maxPills                  = 3,
    fontName                  = "Menlo",
    uiFontName                = ".AppleSystemUIFont",
    fontSize                  = 22,
    modifierFontScale         = 1.0,
    specialFontScale          = 1.0,
    textColor                 = { white = 1 },
    pillBg                    = { white = 0, alpha = 0.68 },
    cornerRadius              = 12,
    pillPadX                  = 12,
    pillPadY                  = 8,
    spacing                   = 8,
    streamTTL                 = 2, -- seconds the strip stays visible since last key
    level                     = hs.canvas.windowLevels.overlay,
    fadeOutDuration           = 0.1,
    -- placement and styling enhancements
    bottomPct                 = 0.2, -- place strip at 20% from bottom of the screen
    pillStroke                = { white = 1, alpha = 0.18 },
    pillStrokeWidth           = 1,
    pillStrokeFn              = { red = 0.3, green = 0.5, blue = 1.0, alpha = 0.35 },
    textShadowOffset          = { x = 0, y = 1 },
    textShadowColor           = { white = 0, alpha = 0.3 },
    textVerticalBiasDefault   = 8,
    textVerticalBiasPunct     = 8,
    textVerticalBiasFn        = 8,
    textVerticalBiasFnWide    = 8,
    textVerticalBiasModifier  = 8,
    textVerticalBiasBackspace = 8,
    textVerticalBiasSpace     = 8,
    spaceLabel                = "Space",
    spaceMinWidth             = 72,
    spaceFontScale            = 1.0,

    -- safety
    blacklistedApps           = { "1Password", "Bitwarden", "Keychain Access" },
}

-- ====== INTERNAL STATE ======
obj._tap           = nil
obj._listenTap     = nil
obj._canvas        = nil
obj._pills         = {} -- { {label=..., w=..., h=..., ts=...}, ... }
obj._hideTmr       = nil
obj._fadeTmr       = nil
obj._lastKey       = { code = nil, when = 0 }
obj._lastPushed    = nil
obj._downMap       = {}
obj._textSizeCache = {}

-- ====== SYMBOLS / MAPS ======
local specials     = {
    ["return"] = "⏎",
    enter = "⌤",
    tab = "⇥",
    space = "␣",
    delete = "⌫",
    forwarddelete = "⌦",
    escape = "ESC",
    up = "↑",
    down = "↓",
    left = "←",
    right = "→",
    home = "↖",
    ["end"] = "↘",
    pageup = "⇞",
    pagedown = "⇟",
    f1 = "F1",
    f2 = "F2",
    f3 = "F3",
    f4 = "F4",
    f5 = "F5",
    f6 = "F6",
    f7 = "F7",
    f8 = "F8",
    f9 = "F9",
    f10 = "F10",
    f11 = "F11",
    f12 = "F12",
    f13 = "F13",
    f14 = "F14",
    f15 = "F15",
    f16 = "F16",
    f17 = "F17",
    f18 = "F18",
    f19 = "F19",
    f20 = "F20",
    f21 = "F21",
    f22 = "F22",
    f23 = "F23",
    f24 = "F24",
    grave = "`",
    ["`"] = "`",
    minus = "−",
    equal = "=",
    leftbracket = "[",
    rightbracket = "]",
    backslash = "\\",
    semicolon = ";",
    quote = "’",
    comma = ",",
    period = ".",
    slash = "/",
}

local modGlyph     = { cmd = "⌘", alt = "⌥", ctrl = "⌃", shift = "⇧", fn = "fn" }

-- ====== HELPERS ======
local function frontAppBlacklisted(blacklist)
    local app = hs.application.frontmostApplication()
    if not app then return false end
    local name = app:name() or ""
    for _, bad in ipairs(blacklist or {}) do
        if name:find(bad, 1, true) then return true end
    end
    return false
end

-- translate keycode -> human label
local keyNameByCode = {}
for name, code in pairs(hs.keycodes.map) do
    keyNameByCode[code] = name
end

local function currentFlagsOfEvent(ev)
    local f = ev:getFlags()
    return { cmd = f.cmd, alt = f.alt, ctrl = f.ctrl, shift = f.shift, fn = f.fn }
end

-- Build a human-friendly "modifier alone" label (⇧, ⌘, etc.)
local function labelForModifiers(flags)
    local out = ""
    for _, m in ipairs({ "ctrl", "alt", "shift", "cmd", "fn" }) do
        if flags[m] then out = out .. modGlyph[m] .. " " end
    end
    local trimmed = out:gsub("%s+$", "")
    -- Ignore bare 'fn' (programmable keyboards often toggle this alone)
    if trimmed == modGlyph.fn or trimmed == "fn" then return nil end
    return (#trimmed > 0) and trimmed or nil
end

local function keyLabel(code, flags, cfg)
    local name = keyNameByCode[code] or ("key" .. tostring(code))
    local base

    -- map special names to glyphs or characters
    if specials[name] then
        base = specials[name]
    elseif name:match("^pad%d$") then
        base = name:sub(4, 4) -- keypad digits -> "0".."9"
    elseif name == "space" then
        base = "␣"
    elseif #name == 1 then
        base = name:upper()
    else
        base = name
    end

    -- Normalize fn+digit to F-keys, and avoid prefixing 'fn' glyph in that case
    local ignoreFnInMods = false
    if flags.fn then
        local d = nil
        if name:match("^%d+$") then
            d = tonumber(name)
        elseif name:match("^pad%d$") then
            d = tonumber(name:sub(4, 4))
        end
        if d then
            base = "F" .. tostring(d)
            ignoreFnInMods = true
        end
    end

    -- Should we show plain characters?
    local anyMod = flags.cmd or flags.alt or flags.ctrl or flags.shift or flags.fn
    if not cfg.showText and not anyMod then
        -- shortcuts-only mode: show only if special (handled above) or modifier-alone (handled elsewhere)
        if specials[name] then
            -- keep
        else
            return nil
        end
    end

    -- prepend modifiers if present
    local out = ""
    for _, m in ipairs({ "ctrl", "alt", "shift", "cmd", "fn" }) do
        if m == "fn" and (ignoreFnInMods or (type(base) == "string" and base:match("^F%d+$"))) then
            -- skip 'fn' when normalized to F-keys OR for any F-key base
        elseif flags[m] then
            out = out .. modGlyph[m] .. " "
        end
    end
    out = out .. base
    return out
end

-- compute pill size for a label (cached)
local function computePillSize(txt, cfg)
    local isSpaceGlyph = type(txt) == "string" and txt:find("␣", 1, true) ~= nil
    local display = txt
    local fontName = cfg.fontName
    local fontSize = cfg.fontSize
    if isSpaceGlyph then
        display = txt:gsub("␣", cfg.spaceLabel or "Space")
        fontName = cfg.uiFontName or cfg.fontName
        fontSize = math.floor((cfg.fontSize or 22) * (cfg.spaceFontScale or 1.0))
    end
    local key = table.concat({ fontName or "", tostring(fontSize or ""), display or "" }, "\31")
    local cached = obj._textSizeCache[key]
    if cached then
        local w = cached.w
        if isSpaceGlyph then
            w = math.max(w, cfg.spaceMinWidth or 0)
        end
        return w, cached.h
    end
    local sz = hs.drawing.getTextDrawingSize(display, {
        font = { name = fontName, size = fontSize },
        paragraphStyle = { alignment = "center" },
    })
    local w = math.ceil(sz.w) + cfg.pillPadX * 2
    local h = math.ceil(sz.h) + cfg.pillPadY * 2
    if isSpaceGlyph then
        w = math.max(w, cfg.spaceMinWidth or 0)
    end
    obj._textSizeCache[key] = { w = w, h = h }
    return w, h
end

local function rebuildCanvas(self)
    local cfg = self.cfg
    local scr = (hs.window.frontmostWindow() and hs.window.frontmostWindow():screen()) or hs.screen.mainScreen()
    local f = scr:frame()

    -- trimming handled at push time to enforce cfg.maxPills

    -- measure
    local totalW, maxH = 0, 0
    for _, p in ipairs(self._pills) do
        local baseDisp = p.label
        if type(baseDisp) == "string" and baseDisp:find("␣", 1, true) then
            baseDisp = baseDisp:gsub("␣", cfg.spaceLabel or "Space")
        end
        -- measure width/height using actual font and size as renderer
        local isModifier = (type(baseDisp) == "string") and
            ((baseDisp:find("⌘") or baseDisp:find("⌥") or baseDisp:find("⌃") or baseDisp:find("⇧")) ~= nil)
        local isBackspace = (baseDisp == "⌫" or baseDisp == "⌦")
        local isSpaceDisp = (type(baseDisp) == "string") and (baseDisp:find(cfg.spaceLabel or "Space", 1, true) ~= nil)
        local textFontName = ((isBackspace or isModifier or isSpaceDisp) and (cfg.uiFontName or cfg.fontName) or cfg.fontName)
        local textSize = (isBackspace and math.floor((cfg.fontSize or 22) * (cfg.specialFontScale or 1.0))
            or (isModifier and math.floor((cfg.fontSize or 22) * (cfg.modifierFontScale or 1.0))
                or (isSpaceDisp and math.floor((cfg.fontSize or 22) * (cfg.spaceFontScale or 1.0)) or cfg.fontSize)))
        if self.cfg.showRepeatCount and p.count and p.count > 1 then
            local prefix = (cfg.repeatCountPrefix or "×")
            local suffixLabel = " " .. prefix .. tostring(p.count)
            local baseSz = hs.drawing.getTextDrawingSize(baseDisp, {
                font = { name = textFontName, size = textSize },
                paragraphStyle = { alignment = "left" },
            })
            local suffixSz = hs.drawing.getTextDrawingSize(suffixLabel, {
                font = { name = textFontName, size = textSize },
                paragraphStyle = { alignment = "left" },
            })
            p.w = math.ceil(baseSz.w + suffixSz.w) + cfg.pillPadX * 2
            p.h = math.ceil(baseSz.h) + cfg.pillPadY * 2
        else
            local sz = hs.drawing.getTextDrawingSize(baseDisp, {
                font = { name = textFontName, size = textSize },
                paragraphStyle = { alignment = "center" },
            })
            if not p.w then p.w = math.ceil(sz.w) + cfg.pillPadX * 2 end
            if not p.h then p.h = math.ceil(sz.h) + cfg.pillPadY * 2 end
        end
        totalW = totalW + p.w
        if p.h > maxH then maxH = p.h end
    end
    if #self._pills > 1 then totalW = totalW + cfg.spacing * (#self._pills - 1) end

    if totalW == 0 then
        if self._canvas then self._canvas:hide() end
        return
    end

    -- canvas frame
    local cx, cy
    cx = f.x + (f.w - totalW) / 2
    if cfg.bottomPct then
        -- place at a fixed percentage from the bottom
        cy = f.y + f.h - maxH - (f.h * cfg.bottomPct)
    else
        if cfg.position == "center" then
            cy = f.y + (f.h - maxH) / 2
        elseif cfg.position == "topcenter" then
            cy = f.y + cfg.screenMargin.y
        else -- bottomcenter
            cy = f.y + f.h - maxH - cfg.screenMargin.y
        end
    end

    if not self._canvas then
        self._canvas = hs.canvas.new({ x = cx, y = cy, w = totalW, h = maxH })
        self._canvas:level(cfg.level)
        -- Behavior: use labels when available, otherwise fall back to numeric flags
        pcall(function()
            if self._canvas.behaviorByLabels then
                self._canvas:behaviorByLabels({ "canJoinAllSpaces", "stationary" })
            elseif self._canvas.behavior and hs.canvas.windowBehaviors then
                local wb = hs.canvas.windowBehaviors
                self._canvas:behavior(wb.canJoinAllSpaces + wb.stationary)
            end
        end)
        if self._canvas.clickPassthrough then self._canvas:clickPassthrough(true) end
    else
        -- Reuse canvas and only update frame/contents
        self._canvas:frame({ x = cx, y = cy, w = totalW, h = maxH })
    end

    -- add elements
    local x = 0
    local defs = {}
    for _, p in ipairs(self._pills) do
        local y0 = math.floor((maxH - p.h) / 2)
        -- Compute text vertical bias based on label content
        local bias = 0
        if type(p.label) == "string" then
            local fnnum = p.label:match("F(%d%d?%d?)") -- matches F1..F24 even if prefixed by "fn "
            if fnnum then
                if #fnnum >= 2 then
                    bias = (cfg.textVerticalBiasFnWide or cfg.textVerticalBiasFn or cfg.textVerticalBiasDefault or 2)
                else
                    bias = (cfg.textVerticalBiasFn or cfg.textVerticalBiasDefault or 2)
                end
            elseif p.label == "⌫" or p.label == "⌦" then
                bias = (cfg.textVerticalBiasBackspace or cfg.textVerticalBiasDefault or 8)
            elseif p.label == "␣" then
                bias = (cfg.textVerticalBiasSpace or cfg.textVerticalBiasDefault or 8)
            elseif (p.label and (p.label:find("⌘") or p.label:find("⌥") or p.label:find("⌃") or p.label:find("⇧"))) then
                bias = (cfg.textVerticalBiasModifier or cfg.textVerticalBiasDefault or 8)
            elseif p.label:match("^%p$") then
                bias = cfg.textVerticalBiasPunct or 0
            else
                bias = cfg.textVerticalBiasDefault or 2
            end
        end
        local yText = y0 + bias
        -- Prepare display label (render ␣ as word)
        local displayLabel = p.label
        if type(p.label) == "string" and p.label:find("␣", 1, true) then
            displayLabel = p.label:gsub("␣", cfg.spaceLabel or "Space")
        end
        local isModifier = (displayLabel and (displayLabel:find("⌘") or displayLabel:find("⌥") or displayLabel:find("⌃") or displayLabel:find("⇧")))
        local isBackspace = (displayLabel == "⌫" or displayLabel == "⌦")
        local isSpaceDisp = (type(displayLabel) == "string") and
            (displayLabel:find(cfg.spaceLabel or "Space", 1, true) ~= nil)

        -- pill background with subtle stroke; accent stroke for function keys
        table.insert(defs, {
            type = "rectangle",
            action = "fill",
            frame = { x = x, y = y0, w = p.w, h = p.h },
            roundedRectRadii = { xRadius = cfg.cornerRadius, yRadius = cfg.cornerRadius },
            fillColor = cfg.pillBg,
            strokeColor = (p.isFn and cfg.pillStrokeFn) or cfg.pillStroke,
            strokeWidth = cfg.pillStrokeWidth,
        })
        -- text shadow and main text
        -- If repeat counter is present, split base and suffix so we can tint the suffix differently
        if self.cfg.showRepeatCount and p.count and p.count > 1 then
            local prefix = (cfg.repeatCountPrefix or "×")
            local suffixLabel = " " .. prefix .. tostring(p.count)
            local baseLabel = displayLabel

            local textFontName = ((isBackspace or isModifier or isSpaceDisp) and (cfg.uiFontName or cfg.fontName) or cfg.fontName)
            local textSize = (isBackspace and math.floor((cfg.fontSize or 22) * (cfg.specialFontScale or 1.0))
                or (isModifier and math.floor((cfg.fontSize or 22) * (cfg.modifierFontScale or 1.0))
                    or (isSpaceDisp and math.floor((cfg.fontSize or 22) * (cfg.spaceFontScale or 1.0)) or cfg.fontSize)))

            local baseSz = hs.drawing.getTextDrawingSize(baseLabel, {
                font = { name = textFontName, size = textSize },
                paragraphStyle = { alignment = "left" },
            })
            local suffixSz = hs.drawing.getTextDrawingSize(suffixLabel, {
                font = { name = textFontName, size = textSize },
                paragraphStyle = { alignment = "left" },
            })
            local totalTextW = baseSz.w + suffixSz.w
            local leftX = x + math.floor((p.w - totalTextW) / 2)

            -- base shadow
            table.insert(defs, {
                type = "text",
                text = baseLabel,
                textFont = textFontName,
                textSize = textSize,
                textColor = cfg.textShadowColor,
                textAlignment = "left",
                frame = { x = leftX + (cfg.textShadowOffset.x or 0), y = yText + (cfg.textShadowOffset.y or 0), w = baseSz.w, h = p.h },
            })
            -- base main
            table.insert(defs, {
                type = "text",
                text = baseLabel,
                textFont = textFontName,
                textSize = textSize,
                textColor = cfg.textColor,
                textAlignment = "left",
                frame = { x = leftX, y = yText, w = baseSz.w, h = p.h },
            })
            -- suffix shadow
            local suffixX = leftX + baseSz.w
            table.insert(defs, {
                type = "text",
                text = suffixLabel,
                textFont = textFontName,
                textSize = textSize,
                textColor = cfg.textShadowColor,
                textAlignment = "left",
                frame = { x = suffixX + (cfg.textShadowOffset.x or 0), y = yText + (cfg.textShadowOffset.y or 0), w = suffixSz.w, h = p.h },
            })
            -- suffix main (dimmed)
            table.insert(defs, {
                type = "text",
                text = suffixLabel,
                textFont = textFontName,
                textSize = textSize,
                textColor = (cfg.repeatCountColor or { white = 0.75, alpha = 1 }),
                textAlignment = "left",
                frame = { x = suffixX, y = yText, w = suffixSz.w, h = p.h },
            })
        else
            -- no repeat counter: draw single centered label
            table.insert(defs, {
                type = "text",
                text = displayLabel,
                textFont = ((isBackspace or isModifier or isSpaceDisp) and (cfg.uiFontName or cfg.fontName) or cfg.fontName),
                textSize = (isBackspace and math.floor((cfg.fontSize or 22) * (cfg.specialFontScale or 1.0))
                    or (isModifier and math.floor((cfg.fontSize or 22) * (cfg.modifierFontScale or 1.0))
                        or (isSpaceDisp and math.floor((cfg.fontSize or 22) * (cfg.spaceFontScale or 1.0)) or cfg.fontSize))),
                textColor = cfg.textShadowColor,
                textAlignment = "center",
                frame = { x = x + (cfg.textShadowOffset.x or 0), y = yText + (cfg.textShadowOffset.y or 0), w = p.w, h = p.h },
            })
            table.insert(defs, {
                type = "text",
                text = displayLabel,
                textFont = ((isBackspace or isModifier or isSpaceDisp) and (cfg.uiFontName or cfg.fontName) or cfg.fontName),
                textSize = (isBackspace and math.floor((cfg.fontSize or 22) * (cfg.specialFontScale or 1.0))
                    or (isModifier and math.floor((cfg.fontSize or 22) * (cfg.modifierFontScale or 1.0))
                        or (isSpaceDisp and math.floor((cfg.fontSize or 22) * (cfg.spaceFontScale or 1.0)) or cfg.fontSize))),
                textColor = cfg.textColor,
                textAlignment = "center",
                frame = { x = x, y = yText, w = p.w, h = p.h },
            })
        end
        x = x + p.w + cfg.spacing
    end

    -- Replace with a proper element array in one call
    self._canvas:replaceElements(defs)
    self._canvas:show()
end

local function queueHide(self)
    if self._hideTmr then self._hideTmr:stop() end
    if self._fadeTmr then
        self._fadeTmr:stop(); self._fadeTmr = nil
    end
    self._hideTmr = hs.timer.doAfter(self.cfg.streamTTL, function()
        local dur = self.cfg.fadeOutDuration or 0
        -- If no fade requested or canvas missing, just hide immediately
        if dur <= 0 or not self._canvas then
            self._pills = {}
            self._lastPushed = nil
            if self._canvas then self._canvas:hide() end
            return
        end

        -- Fade out over duration
        local steps = math.max(10, math.floor(dur / 0.03)) -- ~33ms per step (~30fps)
        local step = 0
        local interval = dur / steps
        self._fadeTmr = hs.timer.doEvery(interval, function()
            step = step + 1
            local a = math.max(0, 1 - (step / steps))
            if self._canvas and self._canvas.alpha then self._canvas:alpha(a) end
            if step >= steps then
                if self._fadeTmr then
                    self._fadeTmr:stop(); self._fadeTmr = nil
                end
                -- clear pills after TTL so stale keys don't reappear
                self._pills = {}
                self._lastPushed = nil
                if self._canvas then self._canvas:hide() end
            end
        end)
    end)
end

local function pushPill(self, label)
    local now = hs.timer.secondsSinceEpoch()
    -- cancel ongoing fade if any and reset alpha
    if self._fadeTmr then
        self._fadeTmr:stop(); self._fadeTmr = nil
    end
    if self._canvas and self._canvas.alpha then self._canvas:alpha(1.0) end
    -- De-dupe very close duplicates (e.g., when both normal and listen-only taps fire)
    if self._lastPushed and self._lastPushed.label == label and (now - self._lastPushed.when) < 0.05 then
        return
    end
    -- If repeating the same key, increment counter on the last pill
    if self.cfg.showRepeatCount then
        local last = self._pills[#self._pills]
        if last and last.label == label and (now - (last.ts or 0)) <= (self.cfg.repeatCountWindow or 1.0) then
            last.count = (last.count or 1) + 1
            last.ts = now
            -- force re-measure to account for "×N" width
            last.w, last.h = nil, nil
            self._lastPushed = { label = label, when = now }
            rebuildCanvas(self)
            queueHide(self)
            return
        end
    end
    local isFn = (type(label) == "string") and (label:match("F%d%d?%d?") ~= nil)
    -- Enforce maxPills==1 as “latest only” by resetting list
    local maxP = self.cfg.maxPills or 8
    if maxP <= 1 then
        self._pills = {}
    end
    table.insert(self._pills, { label = label, ts = now, isFn = isFn, count = 1 })
    -- Enforce maxPills immediately for >1
    while #self._pills > maxP do table.remove(self._pills, 1) end
    self._lastPushed = { label = label, when = now }
    rebuildCanvas(self)
    queueHide(self)
end

-- ====== EVENT TAP ======
local function handleEvent(self, ev)
    if frontAppBlacklisted(self.cfg.blacklistedApps) then return false end
    local t = ev:getType()
    local types = hs.eventtap.event.types
    local now = hs.timer.secondsSinceEpoch()

    -- modifier changes: optionally show modifiers-alone
    if t == types.flagsChanged then
        if self.cfg.showModifiersAlone then
            local flags = currentFlagsOfEvent(ev)
            local lbl = labelForModifiers(flags)
            if lbl and lbl ~= "" then
                pushPill(self, lbl)
            end
        end
        -- moved keyUp handling below (outside flagsChanged)

        return false
    end

    if t == types.keyUp then
        local code = ev:getKeyCode()
        local hadDown = self._downMap[code]
        self._downMap[code] = nil
        if not hadDown then
            local flags = currentFlagsOfEvent(ev)
            local lbl   = keyLabel(code, flags, self.cfg)
            if lbl then pushPill(self, lbl) end
        end
        return false
    end

    if t == types.keyDown then
        -- mark key as down for dedup across keyUp fallback
        self._downMap[ev:getKeyCode()] = true
        -- suppress auto-repeat if requested
        if self.cfg.suppressAutoRepeat then
            local code = ev:getKeyCode()
            local rep = ev:getProperty(hs.eventtap.event.properties.keyboardEventAutorepeat)
            if rep == 1 and self._lastKey.code == code and (now - self._lastKey.when) < 0.2 then
                return false
            end
            self._lastKey.code, self._lastKey.when = code, now
        end

        local flags = currentFlagsOfEvent(ev)
        local code  = ev:getKeyCode()
        local lbl   = keyLabel(code, flags, self.cfg)
        if lbl then pushPill(self, lbl) end
        return false
    end

    return false
end

-- ====== PUBLIC API ======
--- Initialize the Spoon
-- Returns:
--  self - the ShowKeyPresses spoon instance
function obj:init()
    return self
end

--- Start the ShowKeyPresses spoon
-- Parameters:
--  cfg - table|nil with configuration overrides (merged into obj.cfg)
function obj:start(cfg)
    if cfg then for k, v in pairs(cfg) do self.cfg[k] = v end end

    if not hs.accessibilityState() then
        hs.alert.show("Enable Accessibility for Hammerspoon to show keys")
    end

    if self._tap then
        self._tap:stop(); self._tap = nil
    end
    if self._listenTap then
        self._listenTap:stop(); self._listenTap = nil
    end

    local types = { hs.eventtap.event.types.keyDown, hs.eventtap.event.types.keyUp, hs.eventtap.event.types.flagsChanged }
    local cb = function(ev) return handleEvent(self, ev) end

    -- Prefer single listen-only tap; fallback to normal if unavailable
    local ok, tap = pcall(function() return hs.eventtap.new(types, cb, true) end)
    if ok and tap then
        self._tap = tap
    else
        self._tap = hs.eventtap.new(types, cb)
    end
    self._tap:start()

    return self
end

--- Stop the ShowKeyPresses spoon and clean up resources
function obj:stop()
    if self._tap then
        self._tap:stop(); self._tap = nil
    end
    if self._listenTap then
        self._listenTap:stop(); self._listenTap = nil
    end
    if self._canvas then
        self._canvas:delete(); self._canvas = nil
    end
    self._pills = {}
    self._lastPushed = nil
    return self
end

--- Bind hotkeys for ShowKeyPresses
-- Parameters:
--  mapping - table with keys like:
--    toggle = { modsTable, keyString }
function obj:bindHotkeys(mapping)
    if not mapping then return self end
    local spec = {
        toggle = function() if self._tap then self:stop() else self:start() end end
    }
    hs.spoons.bindHotkeysToSpec(spec, mapping)
    return self
end

-- Public API: show a custom label immediately
--- Show a custom label immediately
-- Parameters:
--  label - string label to display as a pill
function obj:showLabel(label)
    if not label or label == "" then return self end
    pushPill(self, tostring(label))
    return self
end

--- Garbage-collector hook to ensure cleanup
function obj:__gc()
    self:stop()
end

return obj
