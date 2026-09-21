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

  Worth knowing if you ever debug this: neither `SLSGetActiveSpace` nor
  `kCGWindowListOptionOnScreenOnly` can tell you what is really on screen. The first reports a
  Space switch ~10ms in while the animation runs for ~400ms more, and the second lists windows
  from other Spaces as "on screen". Both will happily report success while the screen shows
  something else. Verify with a screenshot.
