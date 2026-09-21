# Note: the F6 moon key and Focus modes

## Where it lives

- `src/FocusToggle.swift` — all of the Focus logic (state read, tap vs hold, Shortcuts calls).
- `src/main.swift:14` — `dndKeyCode = 178` (F6 without Fn).
- `src/main.swift:108-116` — the event tap catches F6 keyDown/keyUp, forwards them to
  `handleKeyDown()` / `handleKeyUp()`, and returns `nil` so the system's own DND toggle
  never sees the key.

## Current behavior

Both gestures already short-circuit to "off" when anything is active:

- `onTap()` (`src/FocusToggle.swift:70`) → `isAnyFocusActive() ? "dnd/nothing off" : "dnd on"`
- `onHold()` (`src/FocusToggle.swift:75`, fires after 0.35 s) → `isAnyFocusActive() ? "dnd/nothing off" : "nothing on"`

So the requested rule (any mode enabled → pressing moon disables it) is what's coded today. ✅

`isAnyFocusActive()` reads `~/Library/DoNotDisturb/DB/Assertions.json` directly and counts
`data[0].storeAssertionRecords`. Non-empty means some Focus holds an assertion. Undocumented
but instant, and it fails safe (unreadable or unexpected shape → treated as "no Focus active").

## Status of the pieces

| Piece | State |
| --- | --- |
| Key interception (F6 swallowed at HID level) | ✅ in place |
| Tap → DND on, or off if anything active | ✅ implemented |
| Hold → Nothing on, or off if anything active | ✅ implemented |
| Shortcuts present on this machine (`dnd on`, `nothing on`, `dnd/nothing off`) | ✅ all three listed by `shortcuts list` |
| Full Disk Access (needed to read the TCC-protected assertions file) | ⚠️ must be granted to the built app, else `isAnyFocusActive()` always returns false and the key only ever turns Focus *on* |
| "Off" covering modes other than DND/Nothing (Sleep, Work, Personal, …) | ⚠️ depends on how the `dnd/nothing off` Shortcut is built. A "Turn Focus Off" action with no specific mode clears whatever is active; one pinned to a specific mode would not |

## If it misbehaves

1. The most likely cause of "it turns DND on instead of off" is the assertions read failing,
   which is Full Disk Access going stale after a rebuild (see the signing section in
   `README.md` — ad-hoc signatures invalidate the grant on every build).
2. Second most likely: the `dnd/nothing off` Shortcut is configured for a specific mode
   rather than "Turn Focus Off" generally.
3. `log()` output records every shortcut run and every assertions-read failure, so the log
   distinguishes these two immediately.
