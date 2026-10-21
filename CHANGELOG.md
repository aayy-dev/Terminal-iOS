# Changelog

## 3.1

The first release of Terminal, based on NewTerm 3.0 beta 1. It installs alongside NewTerm.

### New

- Text selection: long press, double or triple tap, drag the handles, Select All, or ⌘A. Copying joins lines the terminal wrapped.
- A toolbar sized like iSH's: ctrl, tab, esc and fn on the left, the arrow keys in the middle, and Select All, Paste and the keyboard key on the right.
- fn works like a Mac's fn key: Home, End, Page Up and Page Down on the arrows, F1 to F12 on the number row, and forward delete.
- Paste lands on the command line at a shell prompt, and nothing runs until you press return. Pasting several lines anywhere else asks first.
- A tap shows the keyboard, selecting text hides it until your next tap, and the keyboard key or a two-finger tap shows or hides it. Scrolling leaves it alone.
- Tabs share one row with the buttons at the top. The password button is an option in Settings > Advanced; ⌘⌥F still works.

### Fixed

- Output stopped updating once the 10,000-line scrollback filled up.
- nano's bottom row was cut off, and the scrollback was lost after vim, less or htop.
- The Settings font preview crashed (hbang/NewTerm#100), the previews showed old values, and font and theme changes only reached open tabs after a relaunch, without the scrollback (hbang/NewTerm#57).
- The bundled fonts weren't in the app, so picking one did nothing.
- New output dragged you back to the bottom while you were scrolled up (hbang/NewTerm#80).
- Chinese, Japanese and Korean characters took an extra column and copied with spaces (hbang/NewTerm#70).
- Bold text changed bright and 256 colors into others, and black and bright black showed as white in dark themes.
- Keys on a hardware keyboard typed twice (hbang/NewTerm#90, hbang/NewTerm#93).
- Closing a tab to the left of the current one showed the wrong tab, a new tab replaced the next one, closed tabs kept their shells running, and exiting one side of a split ended the other.
- ssh:// links could run shell commands from the link. They're now checked and quoted, and also work when they launch the app.
- Shells at 16-character paths such as /var/jb/bin/bash didn't start (hbang/NewTerm#103), and bash could crash on start because of the language setting. Terminal now asks for UTF-8 text in a way iOS supports.
- Big pastes could be cut short, and input could reach a closed tab.
- ⌘K turned off modes the running program had turned on, such as bracketed paste.
- Launch could hang with some keyboard heights, and cancelling the password manager left you without a keyboard.
- The Traditional Chinese translation wasn't included.
- The blank gap above the keyboard is gone.

### Changed

- The About page is gone; its license page crashed. Settings shows the version at the bottom.
- iOS 15 or later is required.
