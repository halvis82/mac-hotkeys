# Note: the F6 moon key and Focus modes

## Where it lives

- `src/FocusToggle.swift` — all of the Focus logic (state read, tap vs hold, Shortcuts calls).
- `src/main.swift` — `dndKeyCode = 178` (F6 without Fn). The event tap catches F6 keyDown/keyUp,
  forwards them to `handleKeyDown()` / `handleKeyUp()`, and returns `nil` so the system's own
  DND toggle never sees the key.

## Behavior

- **tap** → if any Focus is active, turn it off. Otherwise turn on Do Not Disturb.
- **hold** (0.35s) → if any Focus is active, turn it off. Otherwise turn on the "Nothing" Focus.

Both run one of three Shortcuts: `dnd on`, `nothing on`, `dnd/nothing off`. Shortcuts is the only
public way to set a Focus; see README for why.

## Reading the current state

`readFocusState()` reads `~/Library/DoNotDisturb/DB/Assertions.json` and counts
`data[0].storeAssertionRecords`. Non-empty means some Focus holds an assertion.

That file needs **Full Disk Access**. Crucially, a failed read and an empty file are *not* the
same thing, and conflating them is what made the key turn DND on every single time instead of
toggling it off. `readFocusState()` therefore returns nil when it cannot read, and
`isAnyFocusActive()` falls back to `lastKnownFocusActive`, which is updated after every shortcut
that succeeds.

So the key toggles correctly **without** Full Disk Access. The grant only matters if Focus is
also changed from somewhere else (Control Center, a schedule), because then the local guess
drifts until the next successful read.

## Things that bite

| Trap | What happens |
| --- | --- |
| Treating an unreadable assertions file as "no Focus active" | Key only ever turns Focus *on* |
| Waiting on `shortcuts run` without a timeout | It hangs outright sometimes. These run on one serial queue, so one hang blocks every later press and the key goes dead until the agent restarts. A watchdog kills it after 4s |
| Requesting Screen Recording at launch | The moon key has nothing to do with the screen, but the prompt appeared anyway. It is now requested lazily, the first time a switcher preview is drawn |
| `dnd/nothing off` pinned to a specific mode | "Off" would not clear Sleep, Work, Personal and so on. The Shortcut needs a plain "Turn Focus Off" |

## If it misbehaves

`log()` records every shortcut run, every hang it kills, and once per launch whether the
assertions file was readable:

```sh
tail -f ~/Library/Logs/com.halvor.machotkeys.log
```
