# Focus Toggle

Replaces the F6 "moon" key's built-in behavior with:

- **tap** — if any Focus is active, turn it off. Otherwise turn on **Do Not Disturb**.
- **hold** (~0.35s+) — if any Focus is active, turn it off. Otherwise turn on your **Nothing** Focus.

The key normally toggles Do Not Disturb itself before any app sees it. This intercepts it at
the HID level and swallows it, then drives the real Focus state through three small Shortcuts
(the only stable, public way to script macOS Focus — see below).

## Required Shortcuts

Three one-action Shortcuts do the actual Focus switching, because setting a Focus mode is gated
behind an AMFI-restricted entitlement (see "Why Shortcuts" below). They already exist:

| Shortcut name | Action |
|---|---|
| `dnd on` | Set Focus → Do Not Disturb → Turn On |
| `nothing on` | Set Focus → Nothing → Turn On |
| `dnd/nothing off` | Set Focus → Turn Off |

The names must match exactly — the daemon calls `shortcuts run "<name>"`. If you rename them,
update the three constants at the top of `src/main.swift` and re-run `./install.sh`.

## Install

```sh
./install.sh
```

Builds `~/Applications/FocusToggle.app`, installs a LaunchAgent, and starts it. It needs three
permissions, all under **System Settings → Privacy & Security** (add `FocusToggle.app` manually
if no prompt appears):

- **Accessibility** — to intercept the key at all
- **Input Monitoring** — same
- **Full Disk Access** — to read `~/Library/DoNotDisturb/DB/Assertions.json`, which is
  TCC-protected. Without it the read fails with `Operation not permitted`, the daemon thinks no
  Focus is ever active, and every press turns DND *on* instead of toggling.

Note that rebuilding the app changes its code signature, which makes macOS forget these grants.
After any re-run of `install.sh` you may need to toggle the permissions off and on again.

## Uninstall

```sh
./uninstall.sh
```

## How it works

- `src/main.swift` opens a `CGEventTap` at `.cghidEventTap` for keycode **178**, which is what
  the F6 key sends when Fn is *not* held (confirmed by sniffing — it's a normal keyDown/keyUp,
  not one of the hidden "system defined" media-key events like volume/brightness use). Returning
  `nil` from the tap callback swallows it before macOS's own Focus toggle ever sees it.
- Tap vs. hold is timed from keyDown: if the key is still down after 0.35s, the hold action
  fires immediately (no need to wait for release); if it's released first, the tap action fires.
- Current Focus state is read directly from `~/Library/DoNotDisturb/DB/Assertions.json`
  (undocumented, but instant — no process spawn — and verified to update within milliseconds
  of a real Focus change). If Apple changes this file's layout in a future macOS, this check
  degrades safely to "no focus active" rather than crashing.

## Why Shortcuts, and not a direct API

Setting a Focus mode goes through `donotdisturbd`. The private `DoNotDisturb.framework` exposes
exactly the right calls (`DNDModeAssertionService`: `takeModeAssertionWithDetails:error:`,
`invalidateAllActiveModeAssertionsWithError:`), but they're gated on
`com.apple.private.donotdisturb.mode.assertion.client-identifiers`, which is AMFI-restricted:

- Call it without the entitlement → the daemon connects but refuses the reply (`XPC error`).
- Ad-hoc sign a binary that *claims* the entitlement → the kernel SIGKILLs it at launch (exit 137).

Both were verified empirically. Short of disabling SIP/AMFI, the Shortcuts "Set Focus" action is
the only way in, which is exactly what it exists for. Reading state has no such restriction, so
the daemon reads `Assertions.json` directly and only shells out for the writes.

## Troubleshooting

```sh
tail -f ~/Library/Logs/com.halvor.focustoggle.log
```

Every tap/hold logs which shortcut it ran and whether it succeeded.

## Changing the key

Edit `dndKeyCode` in `src/main.swift` (use `../tools/sniff-key.swift` to find another key's
code), then re-run `./install.sh`.
