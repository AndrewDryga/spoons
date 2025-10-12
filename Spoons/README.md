# Hammerspoon Window Management Spoons

This directory contains three Hammerspoon Spoons for window management.

## Installation

Copy these `.spoon` folders to `~/.hammerspoon/Spoons/` or double-click the `.spoon.zip` files to install.

## WindowQuickJump.spoon

Visual badges for instant window jumping. Press a hotkey to show numbered/lettered badges on all windows, then press the corresponding key to jump to that window.

### Quick Start
```lua
hs.loadSpoon("WindowQuickJump")
spoon.WindowQuickJump:bindHotkeys({
    toggle = {{}, "f20"}  -- or {{"cmd", "alt"}, "j"}
}):start()
```

### Configuration
- `maxWindows` - Maximum windows to badge (default: 35)
- `badgeSize` - Badge circle size (default: 28)
- `badgeFontSize` - Font size (default: 15)
- `titleMaxWidth` - Max title width (default: 440)
- `textYOffset` - Text vertical offset (default: -2)
- `badgePadding` - Edge padding (default: 6)

## WindowCycle.spoon

Cycle through windows with automatic space switching. Windows are ordered left-to-right, top-to-bottom.

### Quick Start
```lua
hs.loadSpoon("WindowCycle")
spoon.WindowCycle:bindHotkeys({
    prev = {{}, "f18"},
    next = {{}, "f19"}
}):start()
```

### Configuration
- `debounceMs` - Debounce delay in milliseconds (default: 70)
- `spaceHopDelay` - Delay after space switch in seconds (default: 0.1)

## WindowManager.spoon

Advanced tiling and fullscreen layout management with per-screen profiles.

### Quick Start
```lua
hs.loadSpoon("WindowManager")
spoon.WindowManager:configure({
    profiles = {
        ["Built-in Retina Display"] = {
            layouts = {
                {
                    name = "Development",
                    hotkey = { mods = {"cmd"}, key = "1" },
                    tiling = {
                        { bid = "com.microsoft.VSCode", rect = {0, 0, 0.5, 1} },
                        { bid = "com.googlecode.iterm2", rect = {0.5, 0, 0.5, 1} }
                    }
                }
            }
        }
    }
}):start()
```

### Tiling Rectangle Format
`{x, y, width, height}` where values are 0-1:
- `{0, 0, 0.5, 1}` - Left half
- `{0.5, 0, 0.5, 1}` - Right half
- `{0, 0, 1, 0.5}` - Top half
- `{0.25, 0.25, 0.5, 0.5}` - Center quarter

## Standard Spoon API

All Spoons support:
- `:init()` - Initialize the Spoon
- `:start()` - Start the Spoon
- `:stop()` - Stop the Spoon
- `:bindHotkeys(mapping)` - Bind keyboard shortcuts

## License

MIT - See [LICENSE](../LICENSE)