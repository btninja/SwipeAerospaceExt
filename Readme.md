
![banner](./assets/banner.png)

# About

**SwipeAeroSpaceExtended** is a fork of [MediosZ/SwipeAeroSpace](https://github.com/MediosZ/SwipeAeroSpace) that adds extra 3-finger gestures for AeroSpace. It runs alongside the upstream app (different bundle ID), so you can keep both installed while migrating.

The base behavior — 3-finger swipe LEFT/RIGHT to change AeroSpace workspaces — comes from upstream. This fork adds 3F UP/DOWN, 3F tap, and fn-modified 3F swipes for window movement, monitor focus, and close. See `SPEC.md` for the full gesture set.

# Installation

Build from source until a Homebrew cask is published.

## Build from source

Install Xcode, then either:

- Open `SwipeAeroSpace.xcodeproj` and build the `SwipeAeroSpace` scheme. The output is `SwipeAeroSpaceExtended.app`.
- Or run `xcodebuild -project SwipeAeroSpace.xcodeproj -scheme SwipeAeroSpace -configuration Release` from the project root.

The app needs access to global trackpad events. Grant `SwipeAeroSpaceExtended` access in `System Settings > Privacy & Security > Accessibility`.

# Usage

After installation, use 3-finger gestures to navigate AeroSpace. See `SPEC.md` for the full mapping.

# License

MIT — see the `LICENSE` file. Same license as upstream.

# Acknowledgement

This project is a fork of [MediosZ/SwipeAeroSpace](https://github.com/MediosZ/SwipeAeroSpace). All the multitouch + socket-RPC heavy lifting is upstream's work; this fork adds gestures and a toast HUD on top.

Upstream credits [Touch-Tab](https://github.com/ris58h/Touch-Tab).
