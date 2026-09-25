# mac-hotkeys

A small background agent for macOS that adds three hotkeys. It is one tiny app with no Dock
icon, menu bar item or settings, started at login by a LaunchAgent, with a single keyboard event
tap behind all three.

| Hotkey | What it does | Who it is for |
|---|---|---|
| **Cmd+Tab** | A window switcher: switches between **windows** rather than apps, with live previews, and goes straight to the window you pick, even on another fullscreen Space. Replaces the built-in Cmd+Tab. | Anyone |
| **Cmd+\`** | Cycles the front app's windows, including ones in their own fullscreen Space, which the built-in version skips. | Anyone |
| **F6** (the moon key) | Tap toggles Do Not Disturb, hold turns on a Focus called "Nothing", and either turns an active Focus off. | Set up for one person's Focus modes; see [Customizing the F6 key](#customizing-the-f6-key) |

## The switcher

Hold **Cmd** and press **Tab**. The switcher lists every place you can go, left to right in the
order of your Spaces:

- each fullscreen window (both halves of a split view) is its own tile, with a preview
- each desktop Space is one tile, showing its wallpaper and windows, with one icon per app

While holding Cmd:

| Key | Does |
|---|---|
| **Tab** / **Shift+Tab** | move right / left |
| **1** to **9** | jump to that tile |
| **Left** / **Right** | pick an app within a desktop tile |
| **Esc** | cancel |
| mouse | hover to pick, click to go |

Let go of Cmd to switch. A quick Cmd+Tab flips back to the window you were in before, as the
built-in one does. Minimized windows appear on the first desktop tile, dimmed.

## Requirements

- macOS 14 or later. Developed on macOS 26, Apple Silicon.
- The Xcode Command Line Tools, for `swiftc`: `xcode-select --install`. Nothing else: no
  packages or third-party dependencies, only system frameworks.
- For the F6 key only: the Shortcuts app, and three shortcuts (below).

## Install

```sh
git clone https://github.com/halvis82/mac-hotkeys.git
cd mac-hotkeys
./install.sh
```

This builds `~/Applications/MacHotkeys.app` and a LaunchAgent that starts it at every login and
restarts it if it ever quits, so it survives reboots with nothing more to do. macOS announces
it as a new background item; it is listed under System Settings > General > Login Items &
Extensions, and has to stay allowed there. Run `./install.sh` again after any change to rebuild
and restart. To remove everything: `./uninstall.sh`.

On first run, macOS asks for permissions. Grant them in System Settings > Privacy & Security;
the agent notices within a few seconds, with no restart needed.

- **Accessibility**: required for everything.
- **Screen Recording**: for the switcher's previews only. Asked for the first time a preview is
  drawn. Without it the tiles are blank and everything else works.
- **Full Disk Access**: optional, for the F6 key only. It lets the agent read which Focus is on;
  without it, the key keeps track itself, which is right unless Focus is changed elsewhere.

What it is doing, including how long every Cmd+Tab took:

```sh
tail -f ~/Library/Logs/com.halvor.machotkeys.log
```

### Signing, so permissions survive rebuilds

macOS ties permissions to the app's signature. Without a signing identity `install.sh` signs
ad hoc, and every rebuild then looks like a new app: the old Privacy & Security entry still
shows as enabled but grants nothing, and you have to remove it and grant again. To avoid that,
create a self-signed code-signing certificate once. No sudo, no Apple developer account:

```sh
openssl req -x509 -newkey rsa:2048 -keyout /tmp/sk.pem -out /tmp/codesign.cer -days 3650 -nodes \
  -subj "/CN=Local Codesign" \
  -addext "basicConstraints=critical,CA:false" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning"
openssl pkcs12 -export -out /tmp/id.p12 -inkey /tmp/sk.pem -in /tmp/codesign.cer \
  -passout pass:tmp -legacy -macalg sha1 -name "Local Codesign"
security import /tmp/id.p12 -k ~/Library/Keychains/login.keychain-db -P tmp -T /usr/bin/codesign -A
security add-trusted-cert -r trustRoot -p codeSign -k ~/Library/Keychains/login.keychain-db /tmp/codesign.cer
rm /tmp/sk.pem /tmp/id.p12 /tmp/codesign.cer
```

`install.sh` uses any identity whose name contains "Local Codesign", or the one named in
`SIGN_ID`.

## Customizing the F6 key

The moon key drives Focus through Shortcuts, since that is the only way an app is allowed to
set a Focus (see [Why these use private APIs](#why-these-use-private-apis)). Out of the box it
expects three shortcuts, which you make in the Shortcuts app, each a single action:

| Shortcut name | Action | Run by |
|---|---|---|
| `dnd on` | Set Focus: Do Not Disturb, On | tapping F6 |
| `nothing on` | Set Focus: a Focus of your own (here one called "Nothing"), On | holding F6 |
| `dnd/nothing off` | Turn Focus Off (not tied to a particular Focus) | either, when a Focus is on |

Until all three exist, F6 is left alone and works as the normal moon key; the agent notices
them the next time F6 is pressed. To use other Focus modes, point the shortcuts at them, or rename them and change the three
names at the top of `src/FocusToggle.swift`, where the hold time (0.35s) is too. F6 is key code
178, the moon key on recent MacBook keyboards, set in `src/KeyRouting.swift`; `tools/sniff-key`
prints the code of any other key. More detail is in `NOTES-focus-key.md`.

## Other changes

- **Dropping a hotkey**: remove its case from `routeKey` in `src/KeyRouting.swift`. Keys the
  agent does not claim pass through to macOS untouched.
- **The identifier**: the app and LaunchAgent are `com.halvor.machotkeys`, set in `install.sh`
  and `uninstall.sh`. Change both to your own if you like; permissions are granted per
  identifier, so it means granting them again.

## License

MIT, see [LICENSE](LICENSE). It relies on private macOS APIs (explained below), so a future
macOS update can break parts of it.

# How it works

The rest of this is the design notes: what each part does and why, most of it learned the hard
way. Useful if you change anything.

## Tests

```sh
./test.sh           # unit tests, no permissions needed
./test.sh --live    # also against the real window server, AX and screen capture
./test.sh --bench   # also times the switcher's hot paths, before against after
./test.sh --navigation  # really switches Spaces for about a minute, see below
./test.sh --keys    # types real Cmd+Tab into the installed agent and times it, see below
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

`--keys` needs the agent installed. After a few idle seconds each time, it types a real
Cmd+Tab, checks the panel is up, and cancels with Escape, so nothing switches; then reads the
agent's log for how long each took from the key's own timestamp, which is the delay a person
feels. It ends with one very quick Cmd+Tab tap, which does switch, to check the release is never
missed and the switcher never left stuck open.

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

## Which windows show

Apps own far more windows than they show: toolbars, popups, invisible helpers. A window counts
if it belongs to an ordinary app and sits on a Space; on the current Space, AX also has to
vouch for it; and on a fullscreen Space it has to fill the screen the way a fullscreen or
split-view window does: at least 40% of the biggest window's area, 70% of the tallest's height,
and titled if the same app has a titled window there. The height and title tests were added
when Chrome's address-bar suggestions, a separate window that grows with the list, reached 41%
of the area and showed up as a second Chrome window.

## Starting at login

`install.sh` installs a LaunchAgent: `RunAtLoad` starts the agent at every login, `KeepAlive`
restarts it if it ever exits, and `ProcessType` `Interactive` keeps launchd from running it as a
throttled background job. It keeps no state worth saving between restarts, since window ids do
not survive one; what does persist is the permission grants, as long as the build is signed
with a stable identity (see Signing).

## Keeping Cmd+Tab instant

The switcher sometimes took around 300ms to appear. Three separate things were behind it, found
by timing each phase after the machine had sat idle for a few seconds, which is when it happened:

- **The agent itself was being put to sleep.** An idle agent gets App Nap, and launchd ran it
  as a background job. Window-server calls that take 1ms took 50 to 120ms on the first keypress
  after a quiet spell. The agent now holds a latency-critical activity for its whole life and
  runs as `Interactive`.
- **Other apps were asleep too.** Each app is asked over AX which of its windows are real, and
  a napping app takes 10 to 65ms to wake and answer the first question, sometimes the full
  200ms timeout; after that, a millisecond. So the questions now go out when Command goes down,
  and the apps wake in the gap before Tab. Opening waits at most 30ms for any app still asleep
  and uses its previous answer otherwise, through rules that stop an old answer hiding a window
  opened since. Any other key pressed with Command down (Cmd+N, Cmd+W) makes the early answers
  count as stale again.
- **The main thread was busy.** The keyboard tap lived on the main thread, and so did every
  wait and AX poll of a switch in progress, for up to 1.5 seconds after it. A Cmd+Tab in that
  time queued behind them. The tap now has its own thread, and switching runs on its own queue.

Measured with 4 seconds idle before each open, from Tab to the row being ready, 20 opens:
original code 45ms median, 133ms p90, 253ms worst; now 3.8ms median, 5.7ms p90. Every open now
logs where its time went, from the key's own timestamp, so any delay that comes back names its
cause:

```
open: 4 tiles, sel 2, 9ms (key 0.4, wait 0.1, windows 4.1, panel 3.9), winSpace=none
```

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

Small diagnostics used to build the above, kept because they're useful for extending it. Build
one with `swiftc -o tools/sniff-key tools/sniff-key.swift`.

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
