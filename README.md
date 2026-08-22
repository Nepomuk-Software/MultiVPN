# OpenVPN for Omarchy

A bar widget for `openvpn-client@<profile>.service`. Toggle the tunnel from the
bar, and open a popup for live throughput, connection details and profile
management.

![Preview](preview.png)

- **Bar icon** — dimmed while down, solid while up, pulsing during a transition.
  Optionally shows the current rate next to the icon.
- **Connection** — server endpoint, protocol and port, cipher, tunnel IP,
  interface and MTU, uptime, pushed routes.
- **Throughput** — a sparkline over the last 60 samples plus current rate and
  session totals, read straight from `/sys/class/net/<iface>/statistics`.
- **Profiles** — every config under `/etc/openvpn/client` with its state, click
  to connect or switch, per-profile autostart, credentials and removal.
- **Import** — pick an `.ovpn` file and install it as a named profile.

## Requirements

| Needs | Why |
|---|---|
| `openvpn` with the `openvpn-client@.service` template | the thing being controlled |
| `bash`, `systemctl`, `ip`, `journalctl`, `cat` | reading status, addresses, routes and the connection log |
| membership in a group that can read the system journal (usually `wheel`) | server endpoint and cipher come from the journal |
| `zenity` | the file dialog for importing a config |
| `pkexec` and `python3` | only for profile management, see below |

Reading the journal is optional in practice: without it the panel simply shows
`—` for server and cipher.

## Install

```bash
omarchy plugin add https://github.com/robinnepomukmai/omarchy-openvpn.git --enable
```

Then set the profile the bar icon controls:

```bash
omarchy bar set io.github.robinnepomukmai.openvpn profile work
```

## Privilege boundary

**Everything above works with no elevated privileges.** Status, throughput and
connection details come from unprivileged reads. Bringing the tunnel up and down
uses `systemctl start/stop`, which polkit will ask about unless you have a rule
for it (see below).

**Profile management is the exception.** `/etc/openvpn/client` is `750
openvpn:network`, so listing, importing or removing configs needs root. That is
what `system/install.sh` sets up, and it is a deliberate, separate, manual step —
`omarchy plugin add` never runs installers or `sudo`, and this plugin does not
either. Without it the panel stays fully usable and the profile section says so.

Read the script before running it:

```bash
sudo bash ~/.config/omarchy/plugins/io.github.robinnepomukmai.openvpn/system/install.sh
```

| Path | What it is |
|---|---|
| `/usr/local/bin/omarchy-vpn-admin` | the only thing that writes under `/etc/openvpn/client`; `root:root 0755` |
| `/usr/share/polkit-1/actions/org.omarchy.vpnadmin.policy` | action `org.omarchy.vpnadmin.manage`, `auth_admin_keep` |
| `/etc/systemd/system/omarchy-vpn-cache.{path,service}` | regenerates the cache when the config directory changes |
| `/var/lib/omarchy-vpn/profiles.json` | the profile list the panel reads; `root:wheel 0640` |

Two things worth knowing about the helper:

- On import it reads the source file **with the calling user's privileges**
  (`setresuid` around the read). Otherwise anyone allowed to run the helper
  could have arbitrary root-owned files copied into `/etc/openvpn/client`.
- The cache holds name, remote, port, protocol and whether credentials exist —
  never key material or passwords.

Remove all of it again with:

```bash
sudo bash .../system/install.sh --uninstall
omarchy plugin remove io.github.robinnepomukmai.openvpn
```

### Connecting without a password prompt

`systemctl start openvpn-client@<profile>` is a privileged action. To let your
user do it without an auth dialog, add a polkit rule — for example
`/etc/polkit-1/rules.d/49-openvpn-client.rules`:

```javascript
polkit.addRule(function (action, subject) {
  if (action.id == "org.freedesktop.systemd1.manage-units" &&
      action.lookup("unit").indexOf("openvpn-client@") == 0 &&
      subject.isInGroup("wheel")) {
    return polkit.Result.YES;
  }
});
```

Without it, connecting raises the shell's polkit dialog. That works fine too.

## Usage

| Where | Action |
|---|---|
| Bar, left | open/close the panel |
| Bar, right | tunnel on/off |
| Bar, middle | refresh |
| Panel, `v` | tunnel on/off |
| Panel, `r` | refresh everything |
| Panel, `n` | add a config |
| Panel, ↑ ↓ / Enter | pick a profile and connect |
| Panel, Esc | close an open form, otherwise the panel |

A keybinding for the tunnel, in `~/.config/hypr/bindings.lua`:

```lua
o.bind("SUPER + ALT + V", "VPN toggle", "omarchy-shell io.github.robinnepomukmai.openvpn toggleVpn")
```

## Settings

`omarchy bar set io.github.robinnepomukmai.openvpn <key> <value>`

| Key | Default | Effect |
|---|---|---|
| `profile` | `work` | which `openvpn-client@` instance the icon controls |
| `intervalSec` | `5` | status interval while idle |
| `showRate` | `false` | throughput next to the icon in the bar |
| `highlightWhenConnected` | `false` | connected in the accent colour instead of plain |
| `hideWhenDisconnected` | `false` | hide the icon while the tunnel is down |

`allowMultiple` is on, so you can place one instance per profile.

## IPC

```
omarchy-shell io.github.robinnepomukmai.openvpn <method> [profile]
```

| Method | Does |
|---|---|
| `open` `close` `toggle` | the popup |
| `toggleVpn` `connect` `disconnect` | the connection, on the instance that owns the route |
| `toggleVpnFor` `connectFor` `disconnectFor` `statusFor` | same, addressed at a named profile |
| `refresh` | re-read status and profiles |
| `status` | `connected <ip> rx=<bytes> tx=<bytes>`, `connecting`, or the unit state |

## Developing

Changes to the `.qml` files do **not** reach an already-mounted bar instance,
despite `Local plugin changed, reloading` showing up in the log. Run
`omarchy restart shell` after each change.

## License

MIT — see [LICENSE](LICENSE). Plugins run unsandboxed inside the Omarchy shell;
read the code before you install it.
