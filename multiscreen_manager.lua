-- multiscreen_manager.lua
-- Profile-based layout manager driven entirely by init.lua
--
-- Overview:
-- - Selects active profile by connected screen name (external overrides default)
-- - Builds and applies window_tile_organizer config for the chosen screen
-- - Prints connected display names at boot and after screen changes
--
-- Usage:
--   local manager = require("multiscreen_manager")
--   manager.setup({
--     defaultScreenName = "Built-in Retina Display",
--     profiles = {
--       ["Built-in Retina Display"] = { tiles = { ... }, layouts = { ... }, options = { ... } },
--       ["LG ULTRAGEAR+"]          = { tiles = { ... }, layouts = { ... }, options = { ... } },
--     },
--     debug = false,
--     debounceMs = 800,
--     initialDelayMs = 600,
--     onModeChange = function(activeScreenName) ... end,
--   })
--
-- Notes:
-- - No hardcoded app/layout logic; all configuration comes from profiles.
-- - Per-profile options are forwarded to window_tile_organizer.
-- - targetScreen is injected into each layout as "byName:<screen>".
-- - Spaces are not pre-created here; organizer handles creation/retries per placement.

---@diagnostic disable-next-line: undefined-global, lowercase-global
local hs = hs or {}

local M = {}

-- Dependencies (guarded)
local okOrganizer, organizer = pcall(require, "window_tile_organizer")

-- Internal state
local state = {
    configured = false,
    watcher = nil,
    debounce = nil,
    currentMode = nil,
    options = {},
}

-- Defaults
local DEFAULTS = {
    debug = false,
    debounceMs = 800,
    initialDelayMs = 600,
    -- Default profile when no external profile is active:
    defaultScreenName = "Built-in Retina Display",
    onModeChange = nil,
}

-- Logging
local function logEnabled() return state.options and state.options.debug end
local function log(...)
    if logEnabled() then print("[multiscreen_manager]", ...) end
end

-- Utils
local function screensAll()
    local ok, res = pcall(hs.screen.allScreens)
    return ok and res or {}
end

local function printScreens(prefix)
    local list = screensAll()
    print(string.format("[multiscreen_manager] %s: %d screen(s)", prefix or "screens", #list))
    for i, s in ipairs(list) do
        local name = ""
        local okName, err = pcall(function() name = s:name() or "" end)
        if not okName then name = "<unknown>" end
        print(string.format("[multiscreen_manager]   %d) %s", i, name))
    end
end

local function screenByName(name)
    if not name or name == "" then return nil end
    for _, s in ipairs(screensAll()) do
        if (s.name and s:name() == name) then
            return s
        end
    end
    return nil
end

-- Build configs for window_tile_organizer
-- When profiles are provided from init.lua (state.options.profiles), prefer them over hardcoded builders.
-- We clone layouts and inject targetScreen="byName:<screenName>" to keep organizer routing correct.
local function cloneLayoutsWithTarget(layouts, targetScreenName)
    local out = {}
    for i, l in ipairs(layouts or {}) do
        local copy = {}
        for k, v in pairs(l) do copy[k] = v end
        copy.targetScreen = "byName:" .. (targetScreenName or "")
        out[i] = copy
    end
    return out
end

local function buildProfileConfig(targetScreenName)
    -- Prefer declarative profile if provided via init.lua
    local profiles = state.options and state.options.profiles
    local profile  = profiles and profiles[targetScreenName]
    if profile and type(profile.tiles) == "table" and type(profile.layouts) == "table" then
        local options = {
            debug = state.options.debug,
            autoLaunch = true,
            retryAttempts = 18,
            retryInterval = 0.22,
            scaleToFitIfTooLarge = true,
            padding = 0,
        }
        local cfg = {
            tiles   = profile.tiles,
            layouts = cloneLayoutsWithTarget(profile.layouts, targetScreenName),
            options = options,
        }
        -- Rely on organizer to ensure/create Spaces as needed (no preflight here)
        local firstName = cfg.layouts[1] and cfg.layouts[1].name or nil
        return cfg, firstName
    end

    -- No profile found for target screen; returning nil to keep manager generic
    return nil, nil
end

-- Auto-apply helper: apply a layout a few times with short delays to avoid race conditions
local function autoApplySequence(applyFn)
    local delays = { 0.15, 0.55, 1.0 }
    local i = 1
    local function step()
        local d = delays[i]
        if not d then
            log("autoApplySequence: finished")
            return
        end
        log("autoApplySequence: scheduling step ", i, " after ", d, "s")
        hs.timer.doAfter(d, function()
            log("autoApplySequence: running step ", i)
            pcall(applyFn)
            i = i + 1
            step()
        end)
    end
    step()
end

local function setMode(targetScreenName)
    if state.currentMode == targetScreenName then
        log("Mode unchanged: ", targetScreenName)
        return
    end

    log("Switching profile: ", tostring(state.currentMode), " -> ", tostring(targetScreenName))

    -- Teardown any previous organizer state
    if okOrganizer and organizer and organizer.teardown then
        pcall(function() organizer.teardown() end)
    end

    local cfg, firstName = buildProfileConfig(targetScreenName)
    if not cfg then
        log("No profile found for screen ", tostring(targetScreenName), "; skipping setup")
        return
    end

    organizer.setup(cfg)
    state.currentMode = targetScreenName

    -- Auto-apply sequence
    log("applyProfile: scheduling auto-apply")
    autoApplySequence(function()
        local name = firstName or (cfg.layouts and cfg.layouts[1] and cfg.layouts[1].name)
        log("applyProfile: applying layout ", tostring(name))
        if name and organizer.applyLayout then organizer.applyLayout(name) end
    end)

    local cb = state.options.onModeChange
    if type(cb) == "function" then
        pcall(function() cb(targetScreenName) end)
    end
end

local function recompute()
    printScreens("recompute screens")
    -- Select profile by priority: any connected external profile overrides the default
    local profiles = (state.options and state.options.profiles) or {}
    local defaultName = (state.options and state.options.defaultScreenName) or DEFAULTS.defaultScreenName
    local chosen = defaultName
    for _, s in ipairs(screensAll()) do
        local name = (s.name and s:name()) or ""
        if name ~= defaultName and profiles[name] then
            chosen = name
            break
        end
    end
    setMode(chosen)
end

-- One-time verification sweep to re-apply current mode layout shortly after startup
local function verifyOnceCurrentMode()
    log("verifyOnceCurrentMode: profile=", tostring(state.currentMode))
    local function applyCurrent()
        if not (okOrganizer and organizer and organizer.applyLayout) then
            log("verifyOnceCurrentMode: organizer not ready")
            return
        end
        local targetName =
            state.currentMode or ((state.options and state.options.defaultScreenName) or DEFAULTS.defaultScreenName)
        local _, firstName = buildProfileConfig(targetName)
        log("verifyOnceCurrentMode: layout name=", tostring(firstName))
        if firstName then organizer.applyLayout(firstName) end
    end
    autoApplySequence(applyCurrent)
end

-- Public API

function M.setup(opts)
    if state.configured then return end

    -- Merge options (shallow)
    state.options = {}
    for k, v in pairs(DEFAULTS) do
        if type(v) == "table" then
            local t = {}
            for kk, vv in pairs(v) do
                if type(vv) == "table" then
                    local tt = {}
                    for kkk, vvv in pairs(vv) do tt[kkk] = vvv end
                    t[kk] = tt
                else
                    t[kk] = vv
                end
            end
            state.options[k] = t
        else
            state.options[k] = v
        end
    end
    if type(opts) == "table" then
        for k, v in pairs(opts) do
            if type(v) == "table" and type(state.options[k]) == "table" then
                for kk, vv in pairs(v) do
                    if type(vv) == "table" and type(state.options[k][kk]) == "table" then
                        for kkk, vvv in pairs(vv) do state.options[k][kkk] = vvv end
                    else
                        state.options[k][kk] = vv
                    end
                end
            else
                state.options[k] = v
            end
        end
    end

    printScreens("boot screens")

    -- Debouncer
    local debounceSec = (state.options.debounceMs or DEFAULTS.debounceMs) / 1000
    local pendingTimer = nil
    state.debounce = function(fn)
        if pendingTimer and pendingTimer.stop then pendingTimer:stop() end
        pendingTimer = hs.timer.doAfter(debounceSec, function() fn() end)
    end

    -- Watcher
    state.watcher = hs.screen.watcher.new(function()
        log("Screen event")
        if state.debounce then state.debounce(recompute) end
    end)
    if state.watcher then
        ---@diagnostic disable-next-line: undefined-field
        pcall(function() state.watcher:start() end)
    end

    -- Initial compute after a small delay
    local initialDelaySec = (state.options.initialDelayMs or DEFAULTS.initialDelayMs) / 1000
    hs.timer.doAfter(initialDelaySec, function()
        recompute()
        -- One-time verification sweep after startup
        hs.timer.doAfter(0.6, function()
            verifyOnceCurrentMode()
        end)
    end)

    state.configured = true
    log("multiscreen_manager setup complete")
end

function M.teardown()
    if not state.configured then return end
    if state.watcher then
        ---@diagnostic disable-next-line: undefined-field
        pcall(function() state.watcher:stop() end)
    end
    state.watcher = nil
    if okOrganizer and organizer and organizer.teardown then
        pcall(function() organizer.teardown() end)
    end
    state.currentMode = nil
    state.configured = false
    log("multiscreen_manager teardown complete")
end

function M.forceRecompute()
    recompute()
end

function M.getMode()
    return state.currentMode
end

return M
