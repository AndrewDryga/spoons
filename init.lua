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

-- Arrange windows into predefined tiles/layouts using hotkeys
local window_tile_organizer = require("window_tile_organizer")

local window_organizer_mods = { "cmd" }

local central_window_dimensions = { w = 1714, h = 1520 }
local side_top_window_dimensions = { w = 1059, h = 938 }
local side_bottom_window_dimensions = { w = 1059, h = 580 }

local bundle_ids = {
    zed = "dev.zed.Zed",
    warp = "dev.warp.Warp-Stable",
    chrome = "com.google.Chrome",
    slack = "com.tinyspeck.slackmacgap",
    dash = "com.kapeli.dash",
    chat = "com.openai.chat",
    music = "com.apple.Music",
}

window_tile_organizer.setup({
    tiles = {
        ["Top"]          = { anchor = "top-center", w = central_window_dimensions.w, h = central_window_dimensions.h },
        ["Top Left"]     = { anchor = "top-left", w = side_top_window_dimensions.w, h = side_top_window_dimensions.h },
        ["Top Right"]    = { anchor = "top-right", w = side_top_window_dimensions.w, h = side_top_window_dimensions.h },
        ["Bottom Left"]  = { anchor = "bottom-left", w = side_bottom_window_dimensions.w, h = side_bottom_window_dimensions.h },
        ["Bottom Right"] = { anchor = "bottom-right", w = side_bottom_window_dimensions.w, h = side_bottom_window_dimensions.h },
    },
    layouts = {
        {
            name = "Editor",
            hotkey = { mods = window_organizer_mods, key = "1" },
            focusSpaceTile = { "1", "Top" },
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
            hotkey = { mods = window_organizer_mods, key = "2" },
            focusSpaceTile = { "1", "Top" },
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
            hotkey = { mods = window_organizer_mods, key = "3" },
            focusSpaceTile = { "1", "Top" },
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
    options = {
        debug = config.debug,
        autoLaunch = true,
        wait = { attempts = 20, delay = 0.25 },
        switchSpacesToPlace = true,
        scaleToFitIfTooLarge = true,
        padding = 0,
    },
})
