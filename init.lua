---@diagnostic disable-next-line: undefined-global
local hs = hs

-- Configuration shared by modules
local config = {
    debug = true, -- enable verbose logging
}

-- It is useful to have a visible sign that Hammerspoon has (re)loaded its config
hs.console.clearConsole()
print("")
print("================ Started ================")
print("")

-- Ignore macOS loginwindow in default window filters to silence wfilter warnings
if hs and hs.window and hs.window.filter then
    if hs.window.filter.default and hs.window.filter.default.setAppFilter then
        hs.window.filter.default:setAppFilter('loginwindow', false)
    end
    if hs.window.filter.defaultCurrentSpace and hs.window.filter.defaultCurrentSpace.setAppFilter then
        hs.window.filter.defaultCurrentSpace:setAppFilter('loginwindow', false)
    end
end

-- Cycle through windows using F18/F19
local window_cycle = require("window_cycle")
window_cycle.setup(config)

-- Jump to a window by typing its badge using F20
local window_quick_jump = require("window_quick_jump")
window_quick_jump.setup(config)

-- Declarative per-screen tiles/layouts and multiscreen orchestration
local function printDisplays()
    local list = hs.screen.allScreens()
    print(string.format("[init] screens: %d", #list))
    for i, s in ipairs(list) do
        print(string.format("[init]   %d) %s", i, s:name() or ""))
    end
end

if config.debug then
    printDisplays()
end

-- Diagnostics dump on config reload (no space hopping)
local function diagnosticsDump()
    print("[init] ===== Diagnostics dump (no space hopping) =====")

    -- Screens and spaces
    local screens = hs.screen.allScreens() or {}
    for i, scr in ipairs(screens) do
        local name = scr:name() or ""
        local uuid = scr:getUUID() or ""
        print(string.format("[diag] Screen %d: name='%s' uuid='%s'", i, name, uuid))

        local spaceIds = hs.spaces.spacesForScreen(scr) or {}
        local okAct, activeId = pcall(hs.spaces.activeSpaceOnScreen, scr)
        local activeStr = okAct and tostring(activeId) or "<err>"

        local types = {}
        for _, sid in ipairs(spaceIds) do
            local stype = hs.spaces.spaceType(sid)
            types[#types + 1] = string.format("%s(%s)", tostring(sid), tostring(stype))
        end
        print(string.format("[diag]   spaces: %s; active=%s", table.concat(types, ", "), activeStr))

        -- Count windows per space via windowsForSpace
        for _, sid in ipairs(spaceIds) do
            local okWF, winIds = pcall(hs.spaces.windowsForSpace, sid)
            winIds = okWF and winIds or {}
            print(string.format("[diag]   space %s windows count=%d", tostring(sid), #winIds))
        end
    end

    -- CGWindow index (all spaces)
    local cgIndex = {}
    local okList, cgList = pcall(hs.window.list, true)
    if okList and type(cgList) == "table" then
        for _, rec in ipairs(cgList) do
            local wid = rec.kCGWindowNumber or rec.kCGWindowID or rec["kCGWindowNumber"]
            if wid then cgIndex[wid] = rec end
        end
        print(string.format("[diag] CG list windows=%d", #cgList))
    else
        print("[diag] CG list failed")
    end

    local function describeWindowId(id)
        local rec = cgIndex[id]
        local owner = rec and rec.kCGWindowOwnerName or ""
        local title = rec and rec.kCGWindowName or ""
        local pid = rec and rec.kCGWindowOwnerPID or 0

        local wObj = hs.window.get(id)
        local wInfo
        if wObj then
            local fs = wObj:isFullScreen()
            local minimized = wObj:isMinimized()
            local scr = wObj:screen()
            local sname = scr and scr:name() or ""
            local okWS, wsp = pcall(hs.spaces.windowSpaces, wObj)
            local wspStr = okWS and table.concat(wsp or {}, ",") or "<err>"
            wInfo = string.format("wObj=Y fs=%s min=%s screen='%s' wspaces=[%s]", tostring(fs), tostring(minimized),
                sname, wspStr)
        else
            wInfo = "wObj=N"
        end

        print(string.format("[diag]     win id=%s owner='%s' pid=%s title='%s' %s",
            tostring(id), tostring(owner), tostring(pid), tostring(title), wInfo))
    end

    -- For each screen/space, list windows and map them via CG data; do not switch spaces
    for _, scr in ipairs(screens) do
        local name = scr:name() or ""
        local spaceIds = hs.spaces.spacesForScreen(scr) or {}
        for _, sid in ipairs(spaceIds) do
            local okWF, winIds = pcall(hs.spaces.windowsForSpace, sid)
            winIds = okWF and winIds or {}
            print(string.format("[diag]   listing windows for screen='%s' space=%s (count=%d)", name, tostring(sid),
                #winIds))
            local limit = math.min(#winIds, 20)
            for i = 1, limit do
                describeWindowId(winIds[i])
            end
            if #winIds > limit then
                print(string.format("[diag]   ... %d more windows omitted ...", #winIds - limit))
            end
        end
    end

    -- Running apps and their windows (visible/all)
    local apps = hs.application.runningApplications() or {}
    print(string.format("[diag] running apps=%d", #apps))

    local function dumpWins(label, wins, maxN)
        print(string.format("[diag]   %s:", label))
        local n = 0
        for _, w in ipairs(wins or {}) do
            n = n + 1
            if n > maxN then
                print(string.format("[diag]   ... %d more omitted ...", (#wins) - maxN))
                break
            end
            local wid = w:id()
            local title = w:title() or ""
            local fs = w:isFullScreen()
            local min = w:isMinimized()
            local scr = w:screen()
            local sname = scr and scr:name() or ""
            local okWS, wsp = pcall(hs.spaces.windowSpaces, w)
            local wspStr = okWS and table.concat(wsp or {}, ",") or "<err>"
            print(string.format("[diag]     id=%s title='%s' fs=%s min=%s screen='%s' wspaces=[%s]",
                tostring(wid), title, tostring(fs), tostring(min), sname, wspStr))
        end
    end

    for _, app in ipairs(apps) do
        local name = app:name() or ""
        local bid = app:bundleID() or ""
        local pid = app:pid() or 0
        local hidden = app:isHidden() and "Y" or "N"
        local vWins = (app.visibleWindows and app:visibleWindows()) or {}
        local aWins = (app.allWindows and app:allWindows()) or {}
        print(string.format("[diag] app '%s' bid='%s' pid=%s hidden=%s vWins=%d aWins=%d",
            name, bid, tostring(pid), hidden, #vWins, #aWins))
        dumpWins("visibleWindows", vWins, 20)
        dumpWins("allWindows", aWins, 20)
    end

    print("[init] ===== End diagnostics =====")
end

if config.debug then
    diagnosticsDump()
end

-- Bundle IDs used across layouts
-- You can get Bundle ID using `osascript -e 'id of app "Dash"'`
local bundle_ids = {
    zed    = "dev.zed.Zed",
    warp   = "dev.warp.Warp-Stable",
    chrome = "com.google.Chrome",
    slack  = "com.tinyspeck.slackmacgap",
    dash   = "com.kapeli.dashdoc",
    chat   = "com.openai.chat",
    music  = "com.apple.Music",
}

-- Per-screen declarative configuration:
local screens_config = {
    ["LG ULTRAGEAR+"] = {
        tiles = {
            ["Top"]          = { anchor = "top-center", w = 1714, h = 1520 },
            ["Top Left"]     = { anchor = "top-left", w = 1059, h = 938 },
            ["Top Right"]    = { anchor = "top-right", w = 1059, h = 938 },
            ["Bottom Left"]  = { anchor = "bottom-left", w = 1059, h = 580 },
            ["Bottom Right"] = { anchor = "bottom-right", w = 1059, h = 580 },
        },
        layouts = {
            {
                name = "Editor",
                hotkey = { mods = { "cmd" }, key = "1" },
                focusApp = bundle_ids.zed,
                space_layouts = {
                    [1] = {
                        ["Top"]          = { bundle_ids.zed },
                        ["Top Left"]     = { bundle_ids.slack },
                        ["Bottom Left"]  = { bundle_ids.warp },
                        ["Top Right"]    = { bundle_ids.chrome },
                        ["Bottom Right"] = { bundle_ids.dash, bundle_ids.chat, bundle_ids.music },
                    },
                },
            },
            {
                name = "Browser",
                hotkey = { mods = { "cmd" }, key = "2" },
                focusApp = bundle_ids.chrome,
                space_layouts = {
                    [1] = {
                        ["Top"]          = { bundle_ids.chrome },
                        ["Top Left"]     = { bundle_ids.slack },
                        ["Top Right"]    = { bundle_ids.zed },
                        ["Bottom Left"]  = { bundle_ids.warp },
                        ["Bottom Right"] = { bundle_ids.chat, bundle_ids.music, bundle_ids.dash },
                    },
                },
            },
            -- {
            --     name = "Browser",
            --     hotkey = { mods = { "cmd" }, key = "2" },
            --     focusApp = bundle_ids.chrome,
            --     space_layouts = {
            --         [1] = {
            --             ["Center"]       = { bundle_ids.music },
            --             ["Top Left"]     = { bundle_ids.slack },
            --             ["Top Right"]    = { bundle_ids.dash },
            --             ["Bottom Right"] = { bundle_ids.chat },
            --         },

            --         [2] = { bundle_ids.chrome },
            --         [3] = { bundle_ids.zed },
            --         [4] = { bundle_ids.warp },
            --     },
            -- },
            {
                name = "Terminal",
                hotkey = { mods = { "cmd" }, key = "3" },
                focusApp = bundle_ids.warp,
                space_layouts = {
                    [1] = {
                        ["Top"]          = { bundle_ids.warp },
                        ["Top Left"]     = { bundle_ids.slack },
                        ["Top Right"]    = { bundle_ids.chrome },
                        ["Bottom Left"]  = { bundle_ids.zed },
                        ["Bottom Right"] = { bundle_ids.chat, bundle_ids.music, bundle_ids.dash },
                    },
                },
            },
        },
    },

    ["Built-in Retina Display"] = {
        tiles = {
            ["Center"]       = { anchor = "center", w = 1000, h = 800 },
            ["Top Left"]     = { anchor = "top-left", wPct = 0.5, hPct = 1.00 },
            ["Top Right"]    = { anchor = "top-right", wPct = 0.5, hPct = 0.5 },
            ["Bottom Right"] = { anchor = "bottom-right", wPct = 0.5, hPct = 0.5 },
        },
        layouts = {
            {
                name = "Chrome",
                hotkey = { mods = { "cmd" }, key = "1" },
                focusApp = bundle_ids.chrome,
                space_layouts = {
                    [1] = {
                        ["Center"]       = { bundle_ids.music },
                        ["Top Left"]     = { bundle_ids.slack },
                        ["Top Right"]    = { bundle_ids.dash },
                        ["Bottom Right"] = { bundle_ids.chat },
                    },

                    [2] = { bundle_ids.chrome },
                    [3] = { bundle_ids.zed },
                    [4] = { bundle_ids.warp },
                },
            },
            {
                name = "Editor",
                hotkey = { mods = { "cmd" }, key = "2" },
                focusApp = bundle_ids.zed,
                space_layouts = {
                    [1] = {
                        ["Center"]       = { bundle_ids.music },
                        ["Top Left"]     = { bundle_ids.slack },
                        ["Top Right"]    = { bundle_ids.dash },
                        ["Bottom Right"] = { bundle_ids.chat },
                    },

                    [2] = { bundle_ids.chrome },
                    [3] = { bundle_ids.zed },
                    [4] = { bundle_ids.warp },
                },
            },
            {
                name = "Terminal",
                hotkey = { mods = { "cmd" }, key = "3" },
                focusApp = bundle_ids.warp,
                space_layouts = {
                    [1] = {
                        ["Center"]       = { bundle_ids.music },
                        ["Top Left"]     = { bundle_ids.slack },
                        ["Top Right"]    = { bundle_ids.dash },
                        ["Bottom Right"] = { bundle_ids.chat },
                    },

                    [2] = { bundle_ids.chrome },
                    [3] = { bundle_ids.zed },
                    [4] = { bundle_ids.warp },
                },
            },
        },
    },
}

local window_manager = require("window_manager")

-- Drive the manager from config
window_manager.setup({
    -- Default screen will be used if not other screen matches
    defaultScreenName = "Built-in Retina Display",
    debug = config.debug,
    profiles = screens_config,
})
