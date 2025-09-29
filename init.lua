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

printDisplays()

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
                name = "LaptopSpaces",

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

local multiscreen_manager = require("multiscreen_manager")

-- Drive the manager from config while preserving current behavior.
-- The 'profiles' map is declarative and reusable; the manager will keep using its
-- internal defaults if it ignores unknown keys, so this doesn't break runtime.
multiscreen_manager.setup({
    -- Default screen will be used if not other screen matches
    defaultScreenName = "Built-in Retina Display",
    profiles = screens_config,
})
