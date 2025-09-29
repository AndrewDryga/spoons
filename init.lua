-- Configuration shared by modules
local config = {
    debug = true, -- enable verbose logging
}

-- It is useful to have a visible sign that Hammerspoon has (re)loaded its config
print("")
print("")
print("")
print("")
print("")
print("")
print("")
print("")
print("")
print("")
print("")
print("================ Started ================")
print("")

-- Cycle through windows using F18/F19
local window_cycle = require("window_cycle")
window_cycle.setup(config)

-- Jump to a window by typing its badge using F20
local window_quick_jump = require("window_quick_jump")
window_quick_jump.setup(config)
