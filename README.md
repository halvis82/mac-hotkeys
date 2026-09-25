# mac-hotkeys

One small background agent that replaces things Hammerspoon would otherwise be used for, without
running Hammerspoon. A tiny LSUIElement app started by a LaunchAgent, with a single event tap
driving all three hotkeys. No dock icon, no menu bar item, no UI at all.

| Hotkey | What it does |
|---|---|
| **F6** (moon key) | Tap toggles Do Not Disturb, hold turns on the "Nothing" Focus, and if any Focus is on, either gesture turns it off. |
| **Cmd+`** | Cycles between windows of the front app, including ones fullscreened into their own Space (which macOS's built-in version skips). |
| **Cmd+Tab** | A switcher listing **windows** instead of apps, with previews, ordered by where things actually are. Tab/Shift+Tab to move, **1-9** to jump straight to a tile, arrows to pick an app inside a desktop tile, Esc to cancel, release Cmd to go. |

```sh
./install.sh
```

## Permissions

One app, so permissions are granted once:

- **Accessibility** — required for everything
- **Screen Recording** — switcher previews only, and asked for only the first time a preview is
  actually drawn, so using the moon key alone never raises a screen prompt. Fails quietly: without it tiles render blank
  while everything else keeps working, and `CGPreflightScreenCaptureAccess()` can even report
  `true` while captures are being refused, so trust the tiles rather than the API.
- **Full Disk Access** — optional, and only for the moon key. The file saying which Focus is
  active is TCC-protected; without the grant the key tracks the state itself, which toggles
  correctly unless Focus is also changed from Control Center. Granting it makes that exact.

Input Monitoring is *not* needed in practice; Accessibility covers the event tap.

### Signing, and why it matters

Ad-hoc signatures change on every build, so macOS treats each rebuild as a different app: the
Privacy & Security entry silently goes stale, showing as enabled while granting nothing. To keep
grants across rebuilds, `install.sh` signs with a fixed identity if one exists. Create it once:

```sh
openssl req -x509 -newkey rsa:2048 -keyout /tmp/sk.pem -out ~/halvor-codesign.cer -days 3650 -nodes \
  -subj "/CN=Halvor Local Codesign" \
  -addext "basicConstraints=critical,CA:false" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning"
openssl pkcs12 -export -out /tmp/id.p12 -inkey /tmp/sk.pem -in ~/halvor-codesign.cer \
  -passout pass:tmp -legacy -macalg sha1 -name "Halvor Local Codesign"
security import /tmp/id.p12 -k ~/Library/Keychains/login.keychain-db -P tmp -T /usr/bin/codesign -A
security add-trusted-cert -r trustRoot -p codeSign -k ~/Library/Keychains/login.keychain-db ~/halvor-codesign.cer
```

No sudo needed: trusting it in the user domain is enough.

## Tests

```sh
./test.sh           # unit tests, no permissions needed
./test.sh --live    # also against the real window server, AX and screen capture
./test.sh --bench   # also times the switcher's hot paths, before against after
./test.sh --navigation  # really switches Spaces for about a minute, see below
```

The unit tests cover every key-routing rule, which windows get admitted, how the row is
assembled, selection (Tab, Shift, arrows, numbers, mouse), recency, layout and hit testing,
Window-menu matching, Focus-state parsing and tap versus hold. The pure logic each of those
depends on lives in its own function so it can be tested with made-up windows.

`--live` needs Accessibility and Screen Recording for the terminal running it. It compares the
window listing and thumbnails against `tests/Reference.swift`, a frozen copy of how they worked
before they were made faster, on whatever windows are open, so a speedup that changes an answer
fails a test rather than showing up later as a missing window. It also briefly flashes the
switcher to check it really draws and is gone the moment it is dismissed.

`--navigation` needs one app with two fullscreen windows (two Chrome windows is the case it was
written for) and a window on a desktop. It really switches, and checks every switch three ways:
the Space it ends on, the path it took (sampled every 5ms, which must go straight there), and
the screen itself against the target window's own pixels. It ends with a 30-hop random tour,
since a Space entered the wrong way poisons the switches *after* it. It refuses to run while the
screen is locked, when every switch fails for reasons that have nothing to do with the code.

## Going straight to a window

Activating an app takes macOS to the app's *key* window, not to any window you name. So Cmd+Tab
from the desktop to Chrome window B, when A was the one last used, used to travel to A and then
be redirected to B through the Window menu: two animations and a visible stop at the wrong
window. The redirect was also pressed too early at first, so for a while it ended on A outright.

`KeyWindow` makes B the key window first, by id, with the same private calls AltTab and yabai
use, and the Dock-style activation then goes straight to B. The details all came from measuring,
and each one is load-bearing:

- The key-window calls put the app in front without moving the screen, and the Dock only moves
  to an app it sees *become* active. So focus is handed back to the previous app for a moment
  and the target activated again. Handing back to anything but an ordinary app is not done.
- The app processes the key-window change in its own time, so the hand-back waits until AX
  reports B as key. Handing back first deactivated it with A still key.
- "Handed back" is judged by the window server (`_SLPSGetFrontProcess`) as well as AppKit, which
  trails it. By AppKit alone, 2 in 10 switches from a fullscreen Space did nothing.
- The Dock hears about app changes later still. Activating the moment the hand-back completed
  worked 12 times in 21; 40ms later, 21 of 21, as did 80ms. 50ms is used.
- When B already is the app's key window, none of this is needed and none of it happens.
- A desktop tile shows each app by its *key* window, which AX reports even for an app in the
  background with its key window on another Space. The switcher's own history only sees
  windows change when apps do, so with two Messages windows it named one while activating
  Messages landed on the other. The key window is the app's most recent by definition.
- The wait for the app to confirm B as key is capped at 80ms. It normally confirms in 9 to
  33ms, and some apps never report it at all while in the background.

If any of it fails, the Window-menu redirect is still there as a safety net.

## Where the switcher's time goes

Measured on an M4 with about 170 windows, 16 of them from regular apps, by `./test.sh --bench`,
which runs the old code (kept in `tests/Reference.swift`) and the new side by side:

| Step | Before | After |
|---|---|---|
| Building the row, between Cmd+Tab and the panel | 15 to 29ms median, 48ms worst | 3.5 to 4ms median, 5ms worst |
| Previews on open | blank cards, filled in over 100 to 207ms | last previews at once, fresh ones by about 40ms |
| Redraw per Tab press | same median, but spikes to 34 to 54ms | never above 19ms |
| Panel gone after Cmd is released | about 40ms fade | next frame |
| Switching to an app's other window | two animations, about 720ms | one, arriving in 340 to 390ms |

What made the difference, in case something regresses:

- **The window list itself.** `CGWindowListCopyWindowInfo` is about 4ms of window-server round
  trip and cannot be avoided, but bridging its result to `[[String: Any]]` converted every key of
  every window up front. It is read as `NSDictionary` now, which saves about 1ms.
- **A Space query per window.** Asking which Space each window is on took one window-server
  round trip per window, 50 to 100 of them. Asking each Space for its windows takes one per
  Space, 0.25ms in all instead of about 4ms. See `SkyLight.spaces(ofWindowsOn:)` for how this was
  checked to give exactly the same answers.
- **LaunchServices per window.** `NSRunningApplication(processIdentifier:)` was called twice
  for every window on the system just to learn each app's policy and bundle id. Now once per
  process, and kept between opens until the process quits.
- **AX one app at a time.** Every AX call is a round trip into the target app, so asking eight
  apps in turn cost the *sum* of their response times, and one busy app stalled the rest. They
  are asked in parallel now, and each app's window list is read once rather than twice.
- **Full-size thumbnails resampled on every redraw.** Captures are 1512 points wide for a
  fullscreen window and the tile is 300. They are now scaled once, off the main thread. The
  NSImage keeps its original size in points, so tile geometry is unchanged. This did not make
  the typical redraw faster, which was already about 3ms, but it removed the occasional 30 to
  50ms redraw that made a Tab press hitch.
- **The default window fade.** AppKit fades a panel out over about 40ms on `orderOut`. The
  panel sets `animationBehavior = .none`, which is also what `commit()` assumed all along.

`winSpace` in the log is read the instant the panel is shown. Read a moment later the window
server reports it on a desktop Space even while it is plainly drawing over a fullscreen one,
so only the immediate reading means anything.

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
- **Switching Spaces** has no public API, so SkyLight is called privately. Symbols are resolved
  with `dlsym` so a future macOS renaming one degrades to a clean error.
- **Capturing a window on an inactive Space** is likewise impossible publicly, since an
  unrendered Space returns nothing, so SkyLight's capture call is used. Taking over Cmd+Tab works
  because a HID-level event tap sees the keystroke before the Dock.
- **Leaving a fullscreen Space is the exception**: the private call must *not* be used for it.
  Both `SLSManagedDisplaySetCurrentSpace` and `NSRunningApplication.activate()` leave the
  fullscreen window on screen and draw the target window on top of it, rather than travelling to
  the desktop. Only a Dock-style `NSWorkspace.openApplication` genuinely exits fullscreen, so
  that is what the switcher uses for desktop targets.

- **Reaching a specific window on another fullscreen Space** goes through the app's own Window
  menu, pressed via Accessibility, because that is how macOS itself does it. The menu offers
  nothing but titles to identify a window by, and titles are not unique: two empty Chrome windows
  are both "New Tab", so a title match pressed the same entry whichever one was wanted and
  Cmd+backtick became a silent no-op in one direction. Two things make it reliable. The checkmark
  beside an entry marks the window the app considers current, which is never the destination, so
  unchecked entries are tried first. And only the menu's last section is searched, since that is
  where AppKit lists windows and the sections above it are commands whose names collide with real
  window titles (Chrome has a "Downloads" command, Finder often has a "Downloads" window).

  Worth knowing if you ever debug this: neither `SLSGetActiveSpace` nor
  `kCGWindowListOptionOnScreenOnly` can tell you what is really on screen. The first reports a
  Space switch ~10ms in while the animation runs for ~400ms more, and the second lists windows
  from other Spaces as "on screen". Both will happily report success while the screen shows
  something else. Verify with a screenshot.

  The 10ms figure is for the private switch call. Going the sanctioned way is the opposite:
  polled every 10ms, *entering* a fullscreen Space from the Window menu does not register until
  about 405ms, at the end of the animation. Anything that checks whether a press worked has to
  allow for that, or it declares failure just before the switch lands.
