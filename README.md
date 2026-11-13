# SpaceTags

A macOS menu bar helper that lets you name your Spaces and jump between them from the keyboard.

- **⌘0** opens a switcher showing every space. Press **1–9** to jump, **←/→** and **⏎** to pick, **R** to rename, **C** to change a space's colour.
- **⌃⌥1 … ⌃⌥9** jump straight to space N.
- In **Mission Control**, each named space's label is drawn over its "Desktop N" label in the Spaces bar. On macOS 27 this needs no permission. On macOS 26 and earlier it needs Accessibility; without it the names appear as one strip near the top.
- The menu bar item shows the current space's name and lists all spaces.
- Each named space gets its own colour and a matching emoji in front of its name (unless the name already starts with one), used in the switcher, the Mission Control labels and the menu bar.
- On first launch (and from the menu: **Auto-Name Unnamed Spaces**) unnamed desktops are named after the apps on them, using Apple's on-device model on macOS 26 and the app names elsewhere. The model also picks each space's colour and emoji from the app's palette.
- Names and colours are saved, and the app adds itself to Login Items when run from `/Applications`.

## Install

Apple Silicon, macOS 14 or later.

Download `release/SpaceTags.zip`, unzip it, and open `SpaceTags.app`. The app is ad-hoc signed, so if macOS blocks it, run:

    xattr -dr com.apple.quarantine SpaceTags.app

## Build

Needs the Xcode command line tools (`xcode-select --install`).

    ./build.sh run

`./build.sh install` builds, copies the app to `/Applications` and launches it.

## Notes

- SpaceTags uses private WindowServer APIs; a macOS update can break it. It was developed on macOS 26.5 and 27.2.
- Space numbers follow Mission Control order. Turn off "Automatically rearrange Spaces based on most recent use" in System Settings → Desktop & Dock to keep them stable.
- ⌘0 is captured globally while the app runs.
- Command line: `SpaceTags --goto 2`, `--toggle`, `--name 2=Mail` control the running instance.
