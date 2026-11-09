# SpaceTags

A macOS menu bar helper that lets you name your Spaces and jump between them from the keyboard.

- **⌘0** opens a switcher showing every space. Press **1–9** to jump, **←/→** and **⏎** to pick, **R** to rename.
- **⌃⌥1 … ⌃⌥9** jump straight to space N.
- In **Mission Control**, name labels float over the Spaces bar. With Accessibility granted they sit directly under each space; without it they appear as one strip near the top.
- The menu bar item shows the current space's name and lists all spaces.

## Install

Apple Silicon, macOS 14 or later.

Download `release/SpaceTags.zip`, unzip it, and open `SpaceTags.app`. The app is ad-hoc signed, so if macOS blocks it, run:

    xattr -dr com.apple.quarantine SpaceTags.app

## Build

Needs the Xcode command line tools (`xcode-select --install`).

    ./build.sh run

## Notes

- SpaceTags uses private WindowServer APIs; a macOS update can break it. It was developed on macOS 26.5.
- Space numbers follow Mission Control order. Turn off "Automatically rearrange Spaces based on most recent use" in System Settings → Desktop & Dock to keep them stable.
- ⌘0 is captured globally while the app runs.
- Command line: `SpaceTags --goto 2`, `--toggle`, `--name 2=Mail` control the running instance.
