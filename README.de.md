# VPN für Omarchy

Bar-Widget für OpenVPN, WireGuard und GlobalProtect. Tunnel aus der Bar
schalten, im Popup Durchsatz, Verbindungsdetails und Profilverwaltung.

| Backend | Schalten | Profilliste | Autostart | Import | Zugangsdaten |
|---|---|---|---|---|---|
| **OpenVPN** (`openvpn-client@`) | ja | `/etc/openvpn/client` | ja | ja | ja |
| **WireGuard** (`wg-quick@` und NetworkManager) | ja | `/etc/wireguard` + `nmcli` | ja | ja | entfällt — Schlüssel stehen in der Config |
| **GlobalProtect** (`gpclient`) | Trennen ja, Verbinden wird übergeben | nein | nein | nein | entfällt — SSO |

GlobalProtect ist bewusst der dünne Fall: `gpclient` hat keinen Status-Befehl,
keine systemd-Unit und einen interaktiven SSO-Login. Das Widget schaut also zu,
kann trennen, und reicht das Verbinden an ein Terminal oder die Hersteller-GUI
weiter. Alles, was am Tunnel-Interface hängt — Adresse, Routen, Laufzeit,
Durchsatz — funktioniert für alle drei gleich.

*(English version: [README.md](README.md) — die maßgebliche Fassung.)*

![Vorschau](preview.png)

- **Bar-Icon** — gedimmt wenn getrennt, normal wenn verbunden, pulsierend
  während eines Schaltvorgangs. Optional mit Durchsatz daneben.
- **Verbindung** — Server-Endpunkt, Protokoll und Port, Cipher, Tunnel-IP,
  Interface samt MTU, Laufzeit, gesetzte Routen.
- **Durchsatz** — Sparkline über die letzten 60 Messpunkte, aktuelle Rate und
  Sitzungsvolumen, direkt aus `/sys/class/net/<iface>/statistics`.
- **Profile** — alles, was das Backend kennt, mit Zustand; Klick verbindet oder
  wechselt, dazu Autostart, Zugangsdaten und Entfernen pro Profil. WireGuard
  listet `wg-quick`-Units und NetworkManager-Verbindungen nebeneinander und
  schaltet jede auf ihrem eigenen Weg.
- **Import** — `.ovpn` auswählen und als benanntes Profil installieren.

## Voraussetzungen

Je nach Backend `openvpn`, `wireguard-tools` (für `wg-quick@`),
NetworkManager ab 1.16 (für WireGuard-Verbindungen) oder
`globalprotect-openconnect`. Dazu `bash`, `systemctl`, `ip`, `journalctl`. Für den Dateidialog `zenity`, für die Profilverwaltung zusätzlich
`pkexec` und `python3`. Server und Cipher kommen aus dem Journal — ohne
Leserechte darauf steht dort schlicht `—`.

## Installieren

```bash
omarchy plugin add https://github.com/robinnepomukmai/omarchy-vpn.git --enable
omarchy bar set io.github.robinnepomukmai.vpn backend openvpn
omarchy bar set io.github.robinnepomukmai.vpn profile work
```

## Privilegien-Grenze

**Alles Lesende läuft ohne erhöhte Rechte.** Zustand, Durchsatz und Details
kommen aus unprivilegierten Abfragen. Schalten geht über `systemctl start/stop`
— dafür fragt polkit, sofern keine Regel existiert.

**Ausnahme ist die Profilverwaltung.** `/etc/openvpn/client` ist
`750 openvpn:network`, `/etc/wireguard` gehört root allein — Auflisten,
Importieren und Entfernen brauchen dort also root. WireGuard-Verbindungen, die
NetworkManager gehören, umgehen das komplett: `nmcli` listet sie ohne Rechte,
den Rest regelt Polkit.
Genau das richtet `system/install.sh` ein — als bewusst getrennter, manueller
Schritt. `omarchy plugin add` führt weder Installer noch `sudo` aus, und dieses
Plugin tut es auch nicht. Ohne den Helfer bleibt das Panel voll nutzbar, der
Profilteil sagt dann, was fehlt.

Vorher lesen, dann:

```bash
sudo bash ~/.config/omarchy/plugins/io.github.robinnepomukmai.vpn/system/install.sh
```

Installiert werden `/usr/local/bin/omarchy-vpn-admin` (`root:root 0755`), die
Polkit-Aktion `org.omarchy.vpnadmin.manage`, zwei systemd-Units, die den
Profil-Cache aktuell halten, und `/var/lib/omarchy-vpn/profiles.json`
(`root:wheel 0640`). Rückgängig mit `--uninstall`.

Zwei Details zum Helfer: Beim Import liest er die Quelldatei **mit den Rechten
des Aufrufers**, sonst könnte jeder, der ihn starten darf, beliebige
root-Dateien nach `/etc/openvpn/client` kopieren lassen. Und der Cache enthält
nur Name, Server, Port, Protokoll und ob Zugangsdaten hinterlegt sind — nie
Schlüsselmaterial oder Passwörter.

## Bedienung

| Ort | Aktion |
|---|---|
| Bar, links | Panel auf/zu |
| Bar, rechts | Tunnel an/aus |
| Bar, mitte | neu einlesen |
| Panel, `v` | Tunnel an/aus |
| Panel, `r` | alles neu einlesen |
| Panel, `n` | Config hinzufügen |
| Panel, ↑ ↓ / Enter | Profil wählen und verbinden |
| Panel, Esc | offenes Formular schließen, sonst Panel |

Tastenkombination in `~/.config/hypr/bindings.lua`:

```lua
o.bind("SUPER + ALT + V", "VPN toggle", "omarchy-shell io.github.robinnepomukmai.vpn toggleVpn")
```

## Einstellungen

`omarchy bar set io.github.robinnepomukmai.vpn <key> <value>` —
`backend` (`openvpn`, `wireguard`, `globalprotect`), `profile`, `intervalSec`,
`showRate`, `highlightWhenConnected`, `hideWhenDisconnected`. Details in der [englischen README](README.md).

## Entwickeln

Änderungen an den `.qml`-Dateien erreichen eine bereits eingehängte Bar-Instanz
**nicht**, trotz `Local plugin changed, reloading` im Log. Nach jeder Änderung
`omarchy restart shell`.

## Lizenz

MIT — siehe [LICENSE](LICENSE). Plugins laufen unsandboxed im Omarchy-Shell-
Prozess; lies den Code, bevor du ihn installierst.
