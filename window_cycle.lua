-- window_cycle.lua
-- Window/Space Cycler — Snappy & Production-Ready
--
-- API:
--   local cycle = require("window_cycle")
--   cycle.setup(config)   -- binds hotkeys
--   cycle.teardown()      -- unbinds hotkeys
--
-- Expects config keys:
--   config.debug     : boolean
--   config.lockMs    : number (debounce ms)
--   config.hopSettle : number (seconds to settle after space hop)
--   config.keys.mod  : table (modifier keys)
--   config.keys.prev : string (e.g., "f18")
--   config.keys.next : string (e.g., "f19")

---@diagnostic disable-next-line: undefined-global, lowercase-global
hs = hs or {}

local M = {}

-- Internal state
local state = {
    hotkeys = {},
    configured = false,
}

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

-- Set by setup()
local CONFIG = nil
local LOG = false
local function log(...)
    if LOG then print("[window_cycle]", ...) end
end

-- Helpers & Filters
local function good(w)
    if not (w and w:isVisible() and w:isStandard() and not w:isMinimized()) then return false end
    local app = w:application()
    if app and app:isHidden() then return false end
    local f = w:frame()
    return f and f.w >= 8 and f.h >= 8
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
        local ws = (w and w.screen) and w:screen() or nil
        local sid = ws and ws.id and ws:id() or nil
        local scrid = scr and scr.id and scr:id() or nil
        if sid and scrid and good(w) and sid == scrid then
            table.insert(out, w)
        end
    end
    return sortXthenY(out)
end

-- Space switching with pcall
local function hopAndFocus(scr, dir, which)
    local ok, err = pcall(function()
        local current        = hs.spaces.focusedSpace()
        local spacesByScreen = hs.spaces.allSpaces()
        local all            = (scr and spacesByScreen and spacesByScreen[scr:getUUID()]) or nil
        if not all or not current then error("spaces API unavailable") end
        local idx
        for i, sid in ipairs(all) do if sid == current then idx = i end end
        if not idx then error("current space index not found") end
        local target = ((dir == "right") and (idx < #all and idx + 1 or 1))
            or ((idx > 1 and idx - 1) or #all)
        hs.spaces.gotoSpace(all[target])
        hs.timer.doAfter(((CONFIG and CONFIG.hopSettle) or 0.1), function()
            local wins = windowsOnCurrent(scr)
            local w    = (which == "first" and wins[1]) or wins[#wins]
            if w then
                w:raise(); w:focus()
            end
        end)
    end)
    if not ok then log("hopAndFocus error:", err) end
end

-- Bind hotkeys and logic
local function bindHotkeys()
    local lockSec = (((CONFIG and type(CONFIG.lockMs) == 'number') and CONFIG.lockMs or 70) / 1000)
    local cyclePrev = debounce(lockSec, function()
        local scr = focusedScreen()
        if not scr then return end
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
            local w = list[pos - 1]; if w then
                w:raise(); w:focus()
            end
        end
    end)

    local cycleNext = debounce(lockSec, function()
        local scr = focusedScreen()
        if not scr then return end
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
            local w = list[pos + 1]; if w then
                w:raise(); w:focus()
            end
        end
    end)

    local binder = hs.hotkey and hs.hotkey.bind
    if binder then
        local modsPrev = (CONFIG and CONFIG.keys and CONFIG.keys.mod) or {}
        local keyPrev  = (CONFIG and CONFIG.keys and CONFIG.keys.prev) or "f18"
        local _prev    = binder(modsPrev, keyPrev, cyclePrev)
        if _prev then state.hotkeys.prev = _prev end
        local modsNext = (CONFIG and CONFIG.keys and CONFIG.keys.mod) or {}
        local keyNext  = (CONFIG and CONFIG.keys and CONFIG.keys.next) or "f19"
        local _next    = binder(modsNext, keyNext, cycleNext)
        if _next then state.hotkeys.next = _next end
    end
end

-- Public API

function M.setup(config)
    -- If already configured, teardown and re-bind
    if state.configured then M.teardown() end

    CONFIG           = config or {}
    LOG              = not not (CONFIG and CONFIG.debug)

    -- Sensible defaults if fields are missing
    CONFIG.lockMs    = CONFIG.lockMs or 70
    CONFIG.hopSettle = CONFIG.hopSettle or 0.1
    CONFIG.keys      = CONFIG.keys or {}
    CONFIG.keys.mod  = CONFIG.keys.mod or {}
    CONFIG.keys.prev = CONFIG.keys.prev or "f18"
    CONFIG.keys.next = CONFIG.keys.next or "f19"

    bindHotkeys()
    state.configured = true
    log("window_cycle: setup complete")
end

function M.teardown()
    -- Delete and clear hotkeys
    if state.hotkeys then
        for _, hk in pairs(state.hotkeys) do
            if hk and hk.delete then hk:delete() end
        end
    end
    state.hotkeys = {}
    state.configured = false
    log("window_cycle: teardown complete")
end

return M
