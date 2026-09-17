# Fullscreen Cycle

`Cmd+`` ` that also works across fullscreen Spaces.

macOS's built-in "cycle between windows of the front app" silently skips any window that's been
fullscreened into its own Space, which makes it useless the moment you fullscreen anything. This
replaces it: it finds every real window of the frontmost app, works out which Space each one is
on, switches to that Space when needed, and focuses the window.

## Install

```sh
./install.sh
```

Builds `~/Applications/FullscreenCycle.app`, installs a LaunchAgent, and starts it. Needs two
permissions under **System Settings → Privacy & Security** (add the app manually if no prompt
appears):

- **Accessibility**
- **Input Monitoring**

No Full Disk Access needed, unlike the focus-toggle agent.

Note that rebuilding changes the app's code signature, which makes macOS forget those grants.
After re-running `install.sh` you may need to toggle them off and on again.

## Uninstall

```sh
./uninstall.sh
```

## How it works

1. A `CGEventTap` at `.cghidEventTap` grabs `Cmd+`` ` (keycode 50) and swallows it, so the focused
   app never gets a chance to run the broken built-in behavior.
2. `CGWindowListCopyWindowInfo` gives every window of the frontmost app. Windows smaller than
   200x200, non-zero window layers, and windows the window server hasn't placed on any Space are
   filtered out — that's what removes Chrome's swarm of 1x1 helper windows and floating panels.
3. `SLSCopySpacesForWindows` (private SkyLight) maps each remaining window to its Space.
4. Windows are sorted by window id so the cycle order is stable. Sorting by the raw
   `CGWindowList` order would not work, because that order changes as windows get raised, so the
   cycle would jump around instead of advancing.
5. If the target window is on another Space, `SLSManagedDisplaySetCurrentSpace` switches to it,
   then after a short settle delay the window is raised and focused.

Raising sets `kAXRaiseAction`, `kAXMain` **and** `kAXFocused`. The first two alone change z-order
but leave `kAXFocusedWindow` pointing at the old window, which means the next press would compute
the same "current" window and the cycle would never advance past the second window.

## Private API risk

Space switching has no public API. The SkyLight symbols used here
(`SLSMainConnectionID`, `SLSCopyManagedDisplaySpaces`, `SLSCopySpacesForWindows`,
`SLSManagedDisplaySetCurrentSpace`, `SLSGetActiveSpace`) are resolved at runtime with `dlsym`, so
if Apple renames or removes one, the tool logs an error and exits instead of crashing. Expect to
revisit this after major macOS releases.

## Debugging

```sh
tail -f ~/Library/Logs/com.halvor.fullscreencycle.log
```

The binary also has three flags that work without binding any key:

```sh
./build/fullscreen-cycle --probe              # what it sees for the front app
./build/fullscreen-cycle --probe --pid 1234   # ...for a specific app
./build/fullscreen-cycle --cycle --dry-run    # decide, print, change nothing
./build/fullscreen-cycle --cycle              # perform exactly one cycle
./build/fullscreen-cycle --verbose            # run with per-step Space tracing
```

`--pid` matters when testing from a terminal, since otherwise the terminal itself is the
frontmost app.

## Scope

Only `Cmd+`` ` is bound. `Cmd+Shift+`` ` (reverse cycle) is left to macOS and is still subject to
the original fullscreen limitation.
