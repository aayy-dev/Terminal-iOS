# Terminal

A terminal app for jailbroken iOS 15 and newer, based on [NewTerm 3](https://github.com/hbang/NewTerm) by HASHBANG Productions.

## Changes from NewTerm

- **Text selection.** Long press, double or triple tap, drag the handles, Select All, or ⌘A. Copying joins lines that wrapped on screen.
- **Toolbar.** Sized like iSH's: ctrl, tab, esc and fn on the left, the arrow keys in the middle, and Select All, Paste and the keyboard key on the right.
- **fn key.** Works like a Mac's fn key. With an arrow key it types Home, End, Page Up or Page Down. With the number row it types F1 to F12 (1 to 0, then - and =). With delete it deletes forward.
- **Paste.** At a shell prompt, a paste lands on the command line and nothing runs until you press return. Pasting several lines anywhere else asks first, since each line would run as it arrives.
- **Keyboard.** A tap on the terminal shows the keyboard. Selecting text hides it, and it stays hidden until your next tap. The keyboard key and a two-finger tap show or hide it, and scrolling leaves it alone.
- **Top bar.** Tabs share one row with the buttons. The password button is an option in Settings > Advanced; ⌘⌥F still works.
- **Fixes.** Output no longer stops once the scrollback fills up, the font preview in Settings no longer crashes, and font and theme changes reach open tabs right away. Also fixed: wide characters, colors, doubled hardware keys, tabs and splits, ssh:// links, bash failing to start, cut-off pastes, the gap above the keyboard and more. See [CHANGELOG.md](CHANGELOG.md).

## Installing

Add `https://dev.rtrdd.fyi` in Sileo or Zebra and install Terminal, or install the .deb from [Releases](../../releases). It needs a rootless jailbreak on iOS 15 or later.

## Building

You need Xcode and [Theos](https://theos.dev) with Xcode project support (current Theos has it).

```sh
make package ROOTLESS=1 FINALPACKAGE=1
```

The package is written to `packages/`.

## License

Licensed under the Apache License, version 2.0. See [LICENSE.md](LICENSE.md), which also notes some older code that may be under the GPL.
