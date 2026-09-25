# mac-hotkeys

A small background agent for macOS with three hotkeys. No Dock icon, no menu bar item, no
settings.

- **Cmd+Tab**: a window switcher. Shows every window with a preview, including ones in
  fullscreen Spaces, and goes straight to the one you pick. Replaces the built-in Cmd+Tab.
- **Cmd+\`**: cycles the front app's windows, including fullscreen ones, which the built-in
  version skips.
- **The moon key** (Do Not Disturb, shared with F6): tap or hold to turn a Focus mode on,
  either to turn it off. You choose the Focus modes, see below.

## Using the switcher

Hold Cmd and press Tab. Each fullscreen window gets a tile, and each desktop gets one tile with
an icon per app. While holding Cmd: Tab and Shift+Tab move, 1 to 9 jump to a tile, the arrow
keys pick an app within a desktop, Esc cancels, and the mouse works too. Let go of Cmd to
switch.

## Install

Needs macOS 14 or later and the Xcode Command Line Tools (`xcode-select --install`). Nothing
else.

```sh
git clone https://github.com/halvis82/mac-hotkeys.git
cd mac-hotkeys
./install.sh
```

It starts at every login from then on. Run `./install.sh` again after changing anything, and
`./uninstall.sh` to remove it.

Then grant it, in System Settings > Privacy & Security:

- **Accessibility**: required.
- **Screen Recording**: for the switcher's previews.
- **Full Disk Access**: optional, lets the moon key see Focus changes made elsewhere.

### Keeping permissions across rebuilds

macOS ties permissions to the app's signature, and without a signing certificate every rebuild
counts as a new app that needs granting again. To avoid that, create a self-signed certificate
once:

```sh
openssl req -x509 -newkey rsa:2048 -keyout /tmp/k.pem -out /tmp/c.cer -days 3650 -nodes \
  -subj "/CN=Local Codesign" -addext "basicConstraints=critical,CA:false" \
  -addext "keyUsage=critical,digitalSignature" -addext "extendedKeyUsage=critical,codeSigning"
openssl pkcs12 -export -out /tmp/id.p12 -inkey /tmp/k.pem -in /tmp/c.cer \
  -passout pass:tmp -legacy -macalg sha1 -name "Local Codesign"
security import /tmp/id.p12 -k ~/Library/Keychains/login.keychain-db -P tmp -T /usr/bin/codesign -A
security add-trusted-cert -r trustRoot -p codeSign -k ~/Library/Keychains/login.keychain-db /tmp/c.cer
rm /tmp/k.pem /tmp/c.cer /tmp/id.p12
```

## Setting up the moon key

macOS only lets apps set a Focus through Shortcuts, so the moon key runs three shortcuts you
make in the Shortcuts app:

| Shortcut | Runs when | Typical action |
|---|---|---|
| **Moon Key Tap** | tapped, with no Focus on | Set Focus: Do Not Disturb, on |
| **Moon Key Hold** | held, with no Focus on | Set Focus: any Focus you like, on |
| **Moon Key Off** | tapped or held, with a Focus on | Turn Focus Off |

Until all three exist, the moon key keeps working as normal.

## More

- `tail -f ~/Library/Logs/com.halvor.machotkeys.log` shows what it is doing, including how
  long each Cmd+Tab took.
- `./test.sh` runs the tests. See [NOTES.md](NOTES.md) for the other test modes and how it
  all works.
- It relies on private macOS APIs, so a macOS update can break parts of it.

MIT licensed.
