# Cmd Tab Switcher

Replaces the system Cmd+Tab menu with one that shows **windows** rather than apps, previews what
each one actually looks like, and is ordered by where things really are rather than by recency.

- One tile per fullscreen window, one tile per desktop Space, left to right in window-server
  order, which is the same order Ctrl+Arrow moves through.
- Each tile previews the real window contents with the app icon floating over the bottom left.
- A desktop Space is a single tile no matter how many windows are on it. Its windows appear as a
  grid of icons over the desktop preview.
- Only apps that actually have windows show up.

## Keys

| Key | Action |
|---|---|
| `Cmd+Tab` | Open, then step forward through tiles (wraps) |
| `Cmd+Shift+Tab` | Step backward |
| `Left` / `Right` | On a desktop tile, pick which of its windows to focus. Does nothing on other tiles and stops at the ends |
| `Esc` | Close and stay exactly where you are |
| release `Cmd` | Go to the selected window |

The highlight opens on the **most recently used other window**, not the next tile along, so a
quick Cmd+Tab still flips between your last two windows the way the system one does. Tiles stay
in spatial order regardless.

Selecting a minimized window unminimizes it. Minimized windows have no Space of their own, so
they are attached to the first desktop tile, which is where they restore to anyway.

## Install

```sh
./install.sh
```

Builds `~/Applications/CmdTabSwitcher.app`, installs a LaunchAgent, and starts it. It needs three
permissions under **System Settings → Privacy & Security**:

- **Accessibility** — to read window lists and focus windows
- **Input Monitoring** — to see Cmd+Tab at all
- **Screen Recording** — to capture the window previews

Screen Recording is the one that fails quietly: without it the window server still answers capture
requests but hands back nothing, so every tile renders as an empty card while the switcher
otherwise works perfectly. Note that `CGPreflightScreenCaptureAccess()` can report `true` even
while captures are being refused, so trust the tiles, not the API.

Rebuilding changes the app's code signature, which makes macOS forget all three grants. After
re-running `install.sh` you may need to toggle them off and on again.

## Uninstall

```sh
./uninstall.sh
```

## How it works

- **Taking over Cmd+Tab.** A `CGEventTap` at `.cghidEventTap` sees the keystroke before the Dock
  and returns `nil` to swallow it, which was verified by checking that the Dock's own switcher
  window (a `layer=20` window it owns) never appears. The same tap watches `flagsChanged` so that
  releasing Command is what commits, exactly like the real thing.
- **Ordering.** `SLSCopyManagedDisplaySpaces` returns Spaces per display already in left-to-right
  order. Space type 4 is fullscreen or tiled, type 0 is a desktop.
- **Which windows count.** Enumeration comes from `CGWindowListCopyWindowInfo`, because it is the
  only source that sees windows on other Spaces. Apps are filtered to `.regular` activation
  policy, which drops the window server's own furniture (Stage Manager overlays, the Dock,
  Control Center). On the *active* Space, AX is consulted to reject windows that look real but
  cannot be focused. Elsewhere AX has nothing to say, so a fullscreen Space instead keeps only
  windows comparable in area to its largest, which drops helper windows while keeping both halves
  of a split view.
- **Previews.** `SLSHWCaptureWindowList` captures a window even when its Space isn't active, which
  no public API can do. Captures run about 5ms each, off the main thread, and fill in as they
  arrive so the overlay never waits on them.
- **Desktop previews** are composed by hand: the Dock keeps one wallpaper window per Space named
  after that Space's uuid, which is captured as the backdrop, then that Space's windows are drawn
  on top at their real positions.
- **The overlay** is a non-activating `NSPanel` at `.screenSaver` level that joins all Spaces. It
  must never take focus, or the app being switched away from would stop being frontmost and the
  commit would act on the wrong window.

## Private API risk

Space ordering, cross-Space capture and window ids all come from private SkyLight and
ApplicationServices symbols, resolved with `dlsym` so that a rename in a future macOS produces a
clean startup error rather than a crash. Expect to revisit after major releases.

## Debugging

```sh
tail -f ~/Library/Logs/com.halvor.cmdtabswitcher.log
```

Flags that work without binding any key:

```sh
./build/cmd-tab-switcher --dump              # the tile row as text
./build/cmd-tab-switcher --show 5            # display the overlay for 5 seconds
./build/cmd-tab-switcher --capture-probe DIR # write each tile's capture to disk
./build/cmd-tab-switcher --verbose           # log every open, move and commit
```

## Known rough edge

Building the tile row queries every app over the accessibility API, so the overlay appears a
fraction of a second after the keypress rather than instantly. AX calls are capped at 200ms each
(`AXUIElementSetMessagingTimeout`) so a wedged app cannot freeze the switcher, but the row is
still built from scratch on every open rather than cached.
