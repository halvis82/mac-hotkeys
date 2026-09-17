# mac-hotkeys

Two small background agents that replace things Hammerspoon would otherwise be used for, without
running Hammerspoon. Each is a single Swift file compiled to a tiny LSUIElement app and started by
a LaunchAgent. No dock icon, no menu bar item, no UI at all.

| Tool | What it does |
|---|---|
| [`focus-toggle`](focus-toggle/) | F6 (the moon key): **tap** toggles Do Not Disturb, **hold** turns on the "Nothing" Focus, and if any Focus is already on, either gesture turns it off. |
| [`fullscreen-cycle`](fullscreen-cycle/) | ``Cmd+` `` cycles between windows of the front app, including ones fullscreened into their own Space (which macOS's built-in version skips). |
| [`cmd-tab-switcher`](cmd-tab-switcher/) | Replaces the Cmd+Tab menu with one that lists **windows** instead of apps, previews each one, and orders them by where they actually are. |

Each directory has its own README with install steps, required permissions, and design notes.

```sh
cd focus-toggle && ./install.sh
cd ../fullscreen-cycle && ./install.sh
cd ../cmd-tab-switcher && ./install.sh
```

## Permissions

All three agents need **Accessibility** and **Input Monitoring**. On top of that:

- `focus-toggle` needs **Full Disk Access**, because the file that reports which Focus is
  currently active is TCC-protected.
- `cmd-tab-switcher` needs **Screen Recording** for the window previews. This one fails quietly:
  without it the tiles render blank while everything else keeps working.

Re-running `install.sh` rebuilds the binary, which changes its code signature and makes macOS
forget these grants. After a rebuild you may need to toggle each permission off and back on.

## tools/

Small diagnostics used to build the above, kept because they're useful for extending it:

- `sniff-key` — prints the raw keyboard/system events a key generates. This is how the moon key
  was identified as plain keycode **178** rather than one of the hidden "system defined" media
  events that volume and brightness use.
- `synth-key <keycode> [holdMillis] [cmd|shift|alt|ctrl]` — posts a synthetic keypress, so the
  agents can be tested without a human pressing keys.
- `intercept-test` — proves a `CGEventTap` can swallow a given key before macOS's own handler
  runs.

## Why these use private APIs

Both tools bump into things Apple deliberately doesn't expose, and each README documents what was
tried. Briefly:

- **Setting a Focus mode** is gated behind `com.apple.private.donotdisturb.*` entitlements that
  are AMFI-restricted: claim one and the kernel kills the process at launch, omit it and the
  daemon refuses the request. Shortcuts' "Set Focus" action is the only way in, so `focus-toggle`
  shells out to three one-action Shortcuts.
- **Switching Spaces** has no public API at all, so `fullscreen-cycle` calls SkyLight privately.
  Symbols are resolved with `dlsym` so a future macOS renaming one degrades to a clean error.
- **Capturing a window on an inactive Space** is likewise impossible publicly, since an
  unrendered Space returns nothing, so `cmd-tab-switcher` uses SkyLight's capture call. Taking
  over Cmd+Tab itself works because a HID-level event tap sees the keystroke before the Dock.
