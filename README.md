# VPN for Omarchy

One bar widget for every VPN on the machine. **Unified mode** — the default —
lists OpenVPN profiles, WireGuard interfaces and GlobalProtect portals in a
single panel, follows whichever one is connected, and switches between them
with a click. Buttons add a config or a portal without leaving the panel.

You can also pin an instance to a single backend if you prefer one icon per
VPN; `allowMultiple` is on.

| Backend | Connect / disconnect | Profile list | Autostart | Import | Credentials |
|---|---|---|---|---|---|
| **OpenVPN** (`openvpn-client@`) | yes | `/etc/openvpn/client` | yes | yes | yes |
| **WireGuard** (`wg-quick@` and NetworkManager) | yes | `/etc/wireguard` + `nmcli` | yes | yes | n/a — keys live in the config |
| **GlobalProtect** (`gpclient`) | disconnect yes, connect hands off | no | no | no | n/a — SSO |

Unified mode probes the backends in order and the first live one wins. That is
also the honest model: these tools all fight over the default route, so
activating a connection takes down whatever is up first and starts the new one
when that has finished.

GlobalProtect is deliberately the thin one. `gpclient` has no status command,
no systemd unit and an interactive SSO login, so the widget watches it, can take
it down, and hands connecting to a terminal or the vendor GUI. Everything that
comes off the tunnel interface — address, routes, uptime, throughput — works the
same for all three.

![Preview](preview.png)

- **Bar icon** — dimmed while down, solid while up, pulsing during a transition.
  Optionally shows the current rate next to the icon.
- **Connection** — server endpoint, protocol and port, cipher, tunnel IP,
  interface and MTU, uptime, pushed routes.
- **Throughput** — a sparkline over the last 60 samples plus current rate and
  session totals, read straight from `/sys/class/net/<iface>/statistics`.
- **Profiles** — every config the backend knows about with its state, click to
  connect or switch, per-profile autostart, credentials and removal. WireGuard
  lists `wg-quick` units and NetworkManager connections side by side and
  switches each the right way.
- **Import** — pick a file; the widget works out whether it is OpenVPN or
  WireGuard, suggests a name, and installs it. GlobalProtect portals are added
  by host name instead, since they are not files.

## Requirements

| Needs | Why |
|---|---|
| one of: `openvpn`, `wireguard-tools` (for `wg-quick@`), NetworkManager ≥ 1.16 (for WireGuard connections), `globalprotect-openconnect` | whichever backend you use |
| `bash`, `systemctl`, `ip`, `journalctl`, `cat` | reading status, addresses, routes and the connection log |
| membership in a group that can read the system journal (usually `wheel`) | server endpoint and cipher come from the journal |
| `zenity` | the file dialog for importing a config |
| `pkexec` and `python3` | only for profile management, see below |

Reading the journal is optional in practice: without it the panel simply shows
`—` for server and cipher.

## Install

```bash
omarchy plugin add https://github.com/robinnepomukmai/omarchy-vpn.git --enable
```

That is enough — unified mode needs no configuration. To pin an instance to one
backend instead:

```bash
omarchy bar set io.github.robinnepomukmai.vpn backend openvpn
omarchy bar set io.github.robinnepomukmai.vpn profile work
```

## Privilege boundary

**Everything above works with no elevated privileges.** Status, throughput and
connection details come from unprivileged reads. Bringing the tunnel up and down
uses `systemctl start/stop`, which polkit will ask about unless you have a rule
for it (see below).

**Profile management is the exception.** `/etc/openvpn/client` is `750
openvpn:network` and `/etc/wireguard` is root-only, so listing, importing or
removing those configs needs root. NetworkManager-owned WireGuard connections
skip all of this — `nmcli` lists them unprivileged and polkit governs the rest. That is
what `system/install.sh` sets up, and it is a deliberate, separate, manual step —
`omarchy plugin add` never runs installers or `sudo`, and this plugin does not
either. Without it the panel stays fully usable and the profile section says so.

Read the script before running it:

```bash
sudo bash ~/.config/omarchy/plugins/io.github.robinnepomukmai.vpn/system/install.sh
```

| Path | What it is |
|---|---|
| `/usr/local/bin/omarchy-vpn-admin` | the only thing that writes under `/etc/openvpn/client` and `/etc/wireguard`; `root:root 0755` |
| `/usr/share/polkit-1/actions/org.omarchy.vpnadmin.policy` | action `org.omarchy.vpnadmin.manage`, `auth_admin_keep` |
| `/etc/systemd/system/omarchy-vpn-cache.{path,service}` | regenerates the cache when either config directory changes |
| `/var/lib/omarchy-vpn/profiles.json` | the profile list the panel reads; `root:wheel 0640` |

Two things worth knowing about the helper:

- On import it reads the source file **with the calling user's privileges**
  (`setresuid` around the read). Otherwise anyone allowed to run the helper
  could have arbitrary root-owned files copied into `/etc/openvpn/client`.
- The cache holds name, remote, port, protocol, allowed IPs and whether
  credentials exist — never key material or passwords. WireGuard private keys
  are read past, never copied out.

Remove all of it again with:

```bash
sudo bash .../system/install.sh --uninstall
omarchy plugin remove io.github.robinnepomukmai.vpn
```

### Connecting without a password prompt

`systemctl start openvpn-client@<profile>` (and `wg-quick@<name>`) is a
privileged action. To let your
user do it without an auth dialog, add a polkit rule — for example
`/etc/polkit-1/rules.d/49-openvpn-client.rules`:

```javascript
polkit.addRule(function (action, subject) {
  if (action.id == "org.freedesktop.systemd1.manage-units" &&
      (action.lookup("unit").indexOf("openvpn-client@") == 0 ||
       action.lookup("unit").indexOf("wg-quick@") == 0) &&
      subject.isInGroup("wheel")) {
    return polkit.Result.YES;
  }
});
```

Without it, connecting raises the shell's polkit dialog. That works fine too.

## Where things are stored

| Path | What |
|---|---|
| `/var/lib/omarchy-vpn/profiles.json` | OpenVPN and `wg-quick` profiles, written by the helper |
| NetworkManager | WireGuard connections, read live via `nmcli` |
| `~/.local/state/omarchy-vpn/portals.json` | GlobalProtect portals, owned by you, plain host names |

One known gap: `gpclient` redacts host names in its own log, so when more than
one portal is configured the widget cannot tell which one is connected. It
reports GlobalProtect as connected without marking a row.

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
o.bind("SUPER + ALT + V", "VPN toggle", "omarchy-shell io.github.robinnepomukmai.vpn toggleVpn")
```

## Settings

`omarchy bar set io.github.robinnepomukmai.vpn <key> <value>`

| Key | Default | Effect |
|---|---|---|
| `backend` | `unified` | `unified` for everything at once, or `openvpn` / `wireguard` / `globalprotect` to pin one |
| `profile` | *(empty)* | Pinned modes: which profile the icon controls. Unified mode: the favourite that right-click connects when nothing is up |
| `intervalSec` | `5` | status interval while idle |
| `showRate` | `false` | throughput next to the icon in the bar |
| `highlightWhenConnected` | `false` | connected in the accent colour instead of plain |
| `hideWhenDisconnected` | `false` | hide the icon while the tunnel is down |

## IPC

```
omarchy-shell io.github.robinnepomukmai.vpn <method> [profile]
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
