---@diagnostic disable-next-line: undefined-global
local hs = hs

-- Configuration shared by modules
local config = {
    debug = false, -- enable/disable verbose logging
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

-- Load WindowCycle Spoon (F18/F19 for cycling)
hs.loadSpoon("WindowCycle")
spoon.WindowCycle.debounceMs = 70
spoon.WindowCycle.spaceHopDelay = 0.1
if config.debug then
    spoon.WindowCycle.logger.level = "debug"
end
spoon.WindowCycle:bindHotkeys({
    prev = { { "" }, "f18" },
    next = { { "" }, "f19" }
}):start()

-- Load WindowQuickJump Spoon (F20 for badge jumping)
hs.loadSpoon("WindowQuickJump")
spoon.WindowQuickJump.maxWindows = 35
if config.debug then
    spoon.WindowQuickJump.logger.level = "debug"
end
spoon.WindowQuickJump:bindHotkeys({
    toggle = { { "" }, "f20" }
}):start()

-- Load ShowKeyPresses Spoon (keystroke overlay; load after WindowQuickJump so taps observe digits in number mode)
hs.loadSpoon("ShowKeyPresses")
spoon.ShowKeyPresses:start({
    showText = true, -- shows typed characters too
    position = "center",
    fontSize = 26,
    maxPills = 2,
    pillBg   = { white = 0, alpha = 0.72 },
})

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

-- Bundle IDs used across layouts
-- You can get Bundle ID using `osascript -e 'id of app "Dash"'`
local bundle_ids = {
    zed         = "dev.zed.Zed",
    warp        = "dev.warp.Warp-Stable",
    chrome      = "com.google.Chrome",
    slack       = "com.tinyspeck.slackmacgap",
    dash        = "com.kapeli.dashdoc",
    chatgpt     = "com.openai.chat",
    apple_music = "com.apple.Music",
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
                        ["Bottom Right"] = { bundle_ids.dash, bundle_ids.chatgpt, bundle_ids.apple_music },
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
                        ["Bottom Right"] = { bundle_ids.chatgpt, bundle_ids.apple_music, bundle_ids.dash },
                    },
                },
            },
            -- Used for testing
            -- {
            --     name = "Browser",
            --     hotkey = { mods = { "cmd" }, key = "2" },
            --     focusApp = bundle_ids.chrome,
            --     space_layouts = {
            --         [1] = {
            --             ["Center"]       = { bundle_ids.apple_music },
            --             ["Top Left"]     = { bundle_ids.slack },
            --             ["Top Right"]    = { bundle_ids.dash },
            --             ["Bottom Right"] = { bundle_ids.chatgpt },
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
                        ["Bottom Right"] = { bundle_ids.chatgpt, bundle_ids.apple_music, bundle_ids.dash },
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
                        ["Center"]       = { bundle_ids.apple_music },
                        ["Top Left"]     = { bundle_ids.slack },
                        ["Top Right"]    = { bundle_ids.dash },
                        ["Bottom Right"] = { bundle_ids.chatgpt },
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
                        ["Center"]       = { bundle_ids.apple_music },
                        ["Top Left"]     = { bundle_ids.slack },
                        ["Top Right"]    = { bundle_ids.dash },
                        ["Bottom Right"] = { bundle_ids.chatgpt },
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
                        ["Center"]       = { bundle_ids.apple_music },
                        ["Top Left"]     = { bundle_ids.slack },
                        ["Top Right"]    = { bundle_ids.dash },
                        ["Bottom Right"] = { bundle_ids.chatgpt },
                    },

                    [2] = { bundle_ids.chrome },
                    [3] = { bundle_ids.zed },
                    [4] = { bundle_ids.warp },
                },
            },
        },
    },
}

-- Load WindowManager Spoon for tiling/layout management
hs.loadSpoon("WindowManager")
spoon.WindowManager:configure({
    -- Default screen will be used if not other screen matches
    defaultScreenName = "Built-in Retina Display",
    debug = config.debug,
    notifications = false, -- Enable/disable visual notifications (set to false to disable)
    startup_delay = 0.2,   -- Delay before auto-applying layout on startup (seconds)
    profiles = screens_config,
}):start()
