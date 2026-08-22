# OpenVPN für Omarchy

Bar-Widget für `openvpn-client@<profil>.service`. Tunnel aus der Bar schalten,
im Popup Durchsatz, Verbindungsdetails und Profilverwaltung.

*(English version: [README.md](README.md) — die maßgebliche Fassung.)*

![Vorschau](preview.png)

- **Bar-Icon** — gedimmt wenn getrennt, normal wenn verbunden, pulsierend
  während eines Schaltvorgangs. Optional mit Durchsatz daneben.
- **Verbindung** — Server-Endpunkt, Protokoll und Port, Cipher, Tunnel-IP,
  Interface samt MTU, Laufzeit, gesetzte Routen.
- **Durchsatz** — Sparkline über die letzten 60 Messpunkte, aktuelle Rate und
  Sitzungsvolumen, direkt aus `/sys/class/net/<iface>/statistics`.
- **Profile** — alle Configs unter `/etc/openvpn/client` mit Zustand, Klick
  verbindet oder wechselt, Autostart, Zugangsdaten und Entfernen pro Profil.
- **Import** — `.ovpn` auswählen und als benanntes Profil installieren.

## Voraussetzungen

`openvpn` mit `openvpn-client@.service`, dazu `bash`, `systemctl`, `ip`,
`journalctl`. Für den Dateidialog `zenity`, für die Profilverwaltung zusätzlich
`pkexec` und `python3`. Server und Cipher kommen aus dem Journal — ohne
Leserechte darauf steht dort schlicht `—`.

## Installieren

```bash
omarchy plugin add https://github.com/robinnepomukmai/omarchy-openvpn.git --enable
omarchy bar set io.github.robinnepomukmai.openvpn profile work
```

## Privilegien-Grenze

**Alles Lesende läuft ohne erhöhte Rechte.** Zustand, Durchsatz und Details
kommen aus unprivilegierten Abfragen. Schalten geht über `systemctl start/stop`
— dafür fragt polkit, sofern keine Regel existiert.

**Ausnahme ist die Profilverwaltung.** `/etc/openvpn/client` ist
`750 openvpn:network`, also braucht Auflisten, Importieren und Entfernen root.
Genau das richtet `system/install.sh` ein — als bewusst getrennter, manueller
Schritt. `omarchy plugin add` führt weder Installer noch `sudo` aus, und dieses
Plugin tut es auch nicht. Ohne den Helfer bleibt das Panel voll nutzbar, der
Profilteil sagt dann, was fehlt.

Vorher lesen, dann:

```bash
sudo bash ~/.config/omarchy/plugins/io.github.robinnepomukmai.openvpn/system/install.sh
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
o.bind("SUPER + ALT + V", "VPN toggle", "omarchy-shell io.github.robinnepomukmai.openvpn toggleVpn")
```

## Einstellungen

`omarchy bar set io.github.robinnepomukmai.openvpn <key> <value>` —
`profile`, `intervalSec`, `showRate`, `highlightWhenConnected`,
`hideWhenDisconnected`. Details in der [englischen README](README.md).

## Entwickeln

Änderungen an den `.qml`-Dateien erreichen eine bereits eingehängte Bar-Instanz
**nicht**, trotz `Local plugin changed, reloading` im Log. Nach jeder Änderung
`omarchy restart shell`.

## Lizenz

MIT — siehe [LICENSE](LICENSE). Plugins laufen unsandboxed im Omarchy-Shell-
Prozess; lies den Code, bevor du ihn installierst.
