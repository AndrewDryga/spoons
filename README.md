# Hammerspoon Spoons

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Hammerspoon](https://img.shields.io/badge/Hammerspoon-0.9.81+-blue.svg)](http://www.hammerspoon.org/)
[![macOS](https://img.shields.io/badge/macOS-10.12+-green.svg)](https://www.apple.com/macos/)

A collection of powerful mostly window management Spoons for [Hammerspoon](http://www.hammerspoon.org/), providing efficient keyboard-driven window control for macOS.

Warning! Large chucks of this repo (especially documentation) are vibe-coded, so don't be surprised if you find some crazy stuff.

## 🎯 Features

### Spoons

**Window Management:**

1. **[WindowQuickJump](#windowquickjump)** - Jump to any window instantly with visual badges
2. **[WindowCycle](#windowcycle)** - Cycle through windows and spaces seamlessly
3. **[WindowManager](#windowmanager)** - Advanced tiling and fullscreen layout management
4. **[ShowKeyPresses](#showkeypresses)** - Visualize keystrokes as overlay pills

## 📦 Installation

### Method 1: Direct Download

Download the Spoons directly:
- [WindowQuickJump.spoon.zip](https://github.com/AndrewDryga/spoons/releases/latest/download/WindowQuickJump.spoon.zip)
- [WindowCycle.spoon.zip](https://github.com/AndrewDryga/spoons/releases/latest/download/WindowCycle.spoon.zip)
- [WindowManager.spoon.zip](https://github.com/AndrewDryga/spoons/releases/latest/download/WindowManager.spoon.zip)

Double-click the downloaded `.spoon.zip` files to install.

### Method 2: Git Clone

```bash
git clone https://github.com/AndrewDryga/spoons.git
cd spoons
cp -r Spoons/*.spoon ~/.hammerspoon/Spoons/
```

### Method 3: Manual Installation

1. Download this repository as ZIP
2. Extract and copy the `.spoon` folders to `~/.hammerspoon/Spoons/`

## 🚀 Quick Start

Add to your `~/.hammerspoon/init.lua`:

```lua
-- Load all Spoons
hs.loadSpoon("WindowQuickJump")
hs.loadSpoon("WindowCycle")
hs.loadSpoon("WindowManager")

-- WindowQuickJump: Press Cmd+Alt+J to show window badges
spoon.WindowQuickJump:bindHotkeys({
    toggle = {{"cmd", "alt"}, "j"}
}):start()

-- WindowCycle: Use Cmd+Alt+Arrow keys to cycle windows
spoon.WindowCycle:bindHotkeys({
    prev = {{"cmd", "alt"}, "left"},
    next = {{"cmd", "alt"}, "right"}
}):start()

-- WindowManager: Advanced tiling (see configuration section)
spoon.WindowManager:configure({
    -- Your layout configuration here
}):start()
```

## WindowQuickJump
https://github.com/user-attachments/assets/c9dde70d-4db0-4527-899e-182f6598ff78

Instantly jump to any visible window by displaying keyboard badges (1-9, A-Z) on all windows.

### Features
- **Visual badges** with numbers and letters for up to 35 windows
- **Smart positioning** prevents badge overlap
- **Dark mode support** with automatic theme detection
- **Window title display** with app names

### Configuration

```lua
hs.loadSpoon("WindowQuickJump")

-- Customize appearance (optional)
spoon.WindowQuickJump.maxWindows = 35      -- Maximum windows to badge
spoon.WindowQuickJump.badgeSize = 28       -- Badge circle size
spoon.WindowQuickJump.badgeFontSize = 15   -- Font size
spoon.WindowQuickJump.titleMaxWidth = 440  -- Max title width
spoon.WindowQuickJump.badgePadding = 6     -- Edge padding

-- Bind hotkey
spoon.WindowQuickJump:bindHotkeys({
    toggle = {{"cmd", "alt"}, "j"}
})

spoon.WindowQuickJump:start()
```

### Usage
1. Press your hotkey (e.g., `Cmd+Alt+J`)
2. Press the number/letter shown on the window you want
3. Press `Escape` to cancel

## WindowCycle
https://github.com/user-attachments/assets/8c33d27c-ca43-430a-9578-0e21dd883bfa

Cycle through windows on the current space with automatic space switching at boundaries.

### Features
- **Smart ordering** based on window position (left-to-right, top-to-bottom)
- **Space wrapping** automatically moves to adjacent spaces
- **Debounced input** prevents accidental rapid switching
- **Window filtering** skips minimized and hidden windows

### Configuration

```lua
hs.loadSpoon("WindowCycle")

-- Customize timing (optional)
spoon.WindowCycle.debounceMs = 70        -- Debounce delay (milliseconds)
spoon.WindowCycle.spaceHopDelay = 0.1    -- Delay after space switch (seconds)

-- Bind hotkeys
spoon.WindowCycle:bindHotkeys({
    prev = {{"cmd", "alt"}, "left"},
    next = {{"cmd", "alt"}, "right"}
})

spoon.WindowCycle:start()
```

### Alt-Tab Style Example

```lua
-- Windows/Linux-style Alt-Tab
spoon.WindowCycle:bindHotkeys({
    next = {{"alt"}, "tab"},
    prev = {{"alt", "shift"}, "tab"}
})
```

## ShowKeyPresses

Lightweight keystroke visualizer. Shows typed characters, modifier-only presses, and special keys as floating "pills" overlay.

### Features
- Listen-only event tap when supported (does not intercept keystrokes)
- Show all keys or shortcuts-only
- Modifier-only display (⌘ ⌥ ⌃ ⇧)
- Fade-out with TTL, multiple pills with spacing
- Customizable fonts, colors, and position

### Configuration

```lua
hs.loadSpoon("ShowKeyPresses")

-- Basic example
spoon.ShowKeyPresses:start({
    showText = true,               -- show letters/digits; set false to show only shortcuts/specials
    position = "center",           -- "center" | "bottomcenter" | "topcenter"
    fontSize = 26,
    maxPills = 2,
    pillBg = { white = 0, alpha = 0.72 },
})
```

Optional hotkey to toggle:
```lua
spoon.ShowKeyPresses:bindHotkeys({
    toggle = {{"cmd","alt"}, "k"}
})
```

## WindowManager
https://github.com/user-attachments/assets/90546dfa-cc64-44e8-9f02-777a0120c53e

Advanced window manager with deterministic tiling layouts and fullscreen space management.

I did this because I both work on laptop and connect it to my external monitor, and I wanted to have different layouts for each screen applied automatically: use MacOS spaces on laptop and tiling on larger display.

This Spoon works around MacOS limitations by hopping between spaces and maintaining a window cache.

### Features
- **Per-screen layouts** with automatic profile switching
- **Tile-based layouts** with customizable tile definitions
- **Fullscreen management** with deterministic space ordering
- **App auto-launch** ensures required apps are running
- **Layout hotkeys** for quick layout switching

### Configuration

```lua
hs.loadSpoon("WindowManager")

spoon.WindowManager:configure({
    debug = false,
    notifications = true,

    profiles = {
        ["Built-in Retina Display"] = {
            -- Define reusable tiles for this screen
            tiles = {
                left = { anchor = "left", wPct = 0.5, hPct = 1 },
                right = { anchor = "right", wPct = 0.5, hPct = 1 },
                topleft = { anchor = "topleft", wPct = 0.5, hPct = 0.5 },
                topright = { anchor = "topright", wPct = 0.5, hPct = 0.5 },
                bottomleft = { anchor = "bottomleft", wPct = 0.5, hPct = 0.5 },
                bottomright = { anchor = "bottomright", wPct = 0.5, hPct = 0.5 }
            },

            layouts = {
                {
                    name = "Development",
                    hotkey = { mods = {"cmd", "alt"}, key = "1" },
                    space_layouts = {
                        -- Space 1: Tiled windows
                        [1] = {
                            left = "com.googlecode.iterm2",
                            right = "com.microsoft.VSCode"
                        },
                        -- Space 2+: Fullscreen windows
                        [2] = { "com.google.Chrome" },
                        [3] = { "com.tinyspeck.slackmacgap" }
                    },
                    focusApp = "com.microsoft.VSCode"
                },
                {
                    name = "Communication",
                    hotkey = { mods = {"cmd", "alt"}, key = "2" },
                    space_layouts = {
                        [1] = {
                            left = "com.tinyspeck.slackmacgap",
                            topright = "com.apple.mail",
                            bottomright = "com.apple.iCal"
                        }
                    }
                }
            }
        }
    }
})

spoon.WindowManager:start()
```

### Tile Definitions

Tiles are defined with an anchor point and dimensions:
- `anchor` - Position reference: "topleft", "top", "topright", "left", "center", "right", "bottomleft", "bottom", "bottomright"
- `wPct`, `hPct` - Width/height as percentage of screen (0.0 to 1.0)
- `w`, `h` - Absolute width/height in pixels (alternative to percentages)

### Space Layouts

- **Space 1** (index `[1]`): Used for tiled windows, maps tile names to bundle IDs
- **Spaces 2+** (indices `[2]`, `[3]`, etc.): Used for fullscreen windows, arrays of bundle IDs
- Bundle IDs can be strings or arrays for multiple apps in the same tile/space

### Bundle Identifiers

Find app bundle identifiers using:
```bash
osascript -e 'id of app "Safari"'
# Output: com.apple.Safari
```

## 🔧 Advanced Usage

### Hyper Key Setup

If using Karabiner-Elements to map Caps Lock to Hyper (Cmd+Alt+Ctrl+Shift):

```lua
local hyper = {"cmd", "alt", "ctrl", "shift"}

spoon.WindowQuickJump:bindHotkeys({
    toggle = {hyper, "space"}
})

spoon.WindowCycle:bindHotkeys({
    prev = {hyper, "h"},
    next = {hyper, "l"}
})
```

### Debugging

Enable debug logging:

```lua
spoon.WindowQuickJump.logger.level = "debug"
spoon.WindowCycle.logger.level = "debug"
spoon.WindowManager.debug = true
```

## 📋 Requirements

- macOS 10.12 or later
- [Hammerspoon](http://www.hammerspoon.org/) 0.9.81 or later
- Accessibility permissions for Hammerspoon (System Preferences → Security & Privacy → Privacy → Accessibility)

## 🐛 Troubleshooting

### Hotkeys not working
1. Check Accessibility permissions for Hammerspoon
2. Ensure no other apps are using the same hotkeys
3. Reload Hammerspoon config (`Cmd+R` in console)

### Badges/Windows not appearing
1. Check that windows are on the current space
2. Minimized and hidden windows are intentionally skipped
3. Try increasing `maxWindows` if you have many windows

### Space switching issues
1. Mission Control must be enabled
2. Full-screen apps may interfere with space switching
3. Check Console.app for error messages

## 📖 API Documentation

Each Spoon provides standard methods:

- `:init()` - Initialize the Spoon
- `:start()` - Start the Spoon
- `:stop()` - Stop the Spoon
- `:bindHotkeys(mapping)` - Bind keyboard shortcuts

See individual Spoon sections above for specific configuration options.

## 🤝 Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

1. Fork the repository
2. Create your feature branch (`git checkout -b feature/AmazingFeature`)
3. Commit your changes (`git commit -m 'Add some AmazingFeature'`)
4. Push to the branch (`git push origin feature/AmazingFeature`)
5. Open a Pull Request

## 📄 License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## 🙏 Acknowledgments

- [Hammerspoon](http://www.hammerspoon.org/) community for the excellent automation framework

## 👤 Author

**Andrew Dryga**

- GitHub: [@AndrewDryga](https://github.com/AndrewDryga)

## ⭐ Show your support

Give a ⭐️ if this project helped you!

Made with ❤️ for the Hammerspoon community
