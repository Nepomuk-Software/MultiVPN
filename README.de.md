# MultiVPN für Omarchy

Ein Bar-Widget für alle VPNs der Maschine. Der **Unified-Modus** — die
Voreinstellung — listet OpenVPN-Profile, OpenVPN-3-Configs,
WireGuard-Interfaces und GlobalProtect-Portale in einem Panel, folgt der
jeweils verbundenen Lösung und wechselt per Klick. Knöpfe fügen eine Config
oder ein Portal hinzu, ohne das Panel zu verlassen.

Wer lieber ein Icon pro VPN will, kann eine Instanz auf ein Backend festnageln;
`allowMultiple` ist an.

| Backend | Schalten | Profilliste | Autostart | Import | Zugangsdaten |
|---|---|---|---|---|---|
| **OpenVPN** (`openvpn-client@` und NetworkManager) | ja | `/etc/openvpn/client` + `nmcli` | ja | ja | systemd: gespeichert; NM: Prompt beim Verbinden |
| **OpenVPN 3** (`openvpn3`-D-Bus-Sitzungsmanager) | ja | `openvpn3 configs-list` | nein | ja | beim Sitzungsstart — SSO öffnet den Browser |
| **WireGuard** (`wg-quick@` und NetworkManager) | ja | `/etc/wireguard` + `nmcli` | ja | ja | entfällt — Schlüssel stehen in der Config |
| **GlobalProtect** (`gpclient`) | Trennen ja, Verbinden wird übergeben | nein | nein | nein | entfällt — SSO |

Der Unified-Modus meldet **alle** laufenden Verbindungen, nicht nur eine.
Split-Tunnel vertragen sich problemlos — ein OpenVPN-Profil, das zwei
Büro-Subnetze pusht, und ein WireGuard-Tunnel für ein paar /16er kommen sich
nicht ins Gehege. Eine Verbindung zu aktivieren baut die anderen also nicht ab.
Sind mehrere verbunden, wählt eine Leiste aus, welche der Detail- und
Durchsatzblock beschreibt.

Der einzige echte Konflikt ist die Default-Route, und die beanspruchen nur
Full-Tunnel-Configs. Tun das zwei gleichzeitig, sagt das Panel es — statt es zu
verhindern.

OpenVPN 3 ist der andere OpenVPN-Stack und mit Absicht ein eigenes Backend —
beide koexistieren auf einer Maschine, und das Panel entscheidet Fähigkeiten
pro Zeile. Es ist ein D-Bus-Sitzungsmanager pro Benutzer, gesteuert über das
unprivilegierte `openvpn3`-CLI: Auflisten, Importieren, Verbinden und
Entfernen laufen also nie über den Root-Helfer oder dessen Cache — Polkit
regelt die D-Bus-Dienste. Ein Profil mit Web-Login verbindet nicht einfach:
das Widget startet die Sitzung, öffnet die ausgegebene Auth-URL im Browser
und wartet, bis die Sitzung sich als verbunden meldet. Nach ~120 s hört es
auf zu warten, lässt die Sitzung aber stehen — ein spät abgeschlossener
Login verbindet also trotzdem. Autostart bleibt vorerst aus:
`openvpn3-session@`-Units wollen root-eigene persistente Configs.

GlobalProtect ist bewusst der dünne Fall: `gpclient` hat keinen Status-Befehl,
keine systemd-Unit und einen interaktiven SSO-Login. Das Widget schaut also zu,
kann trennen, und reicht das Verbinden an ein Terminal oder die Hersteller-GUI
weiter. Alles, was am Tunnel-Interface hängt — Adresse, Routen, Laufzeit,
Durchsatz — funktioniert für alle drei gleich.

*(English version: [README.md](README.md) — die maßgebliche Fassung.)*

![Vorschau](preview.png)

- **Bar-Icon** — gedimmt wenn getrennt, normal wenn verbunden, pulsierend
  während eines Schaltvorgangs. Optional mit Durchsatz daneben.
- **Ein Schalter pro VPN**, in dessen eigener Zeile. Es gibt keinen globalen
  Schalter: wenn mehrere Verbindungen gleichzeitig möglich sind, müsste ein
  einzelner Schalter oben stillschweigend eine davon auswählen.
- **Verbindung** — Server-Endpunkt, Protokoll und Port, Cipher, Tunnel-IP,
  Interface samt MTU, Laufzeit, gesetzte Routen.
- **Durchsatz** — Sparkline über die letzten 60 Messpunkte, aktuelle Rate und
  Sitzungsvolumen, direkt aus `/sys/class/net/<iface>/statistics`. WireGuard
  zählt beide Richtungen. OpenVPN mit **DCO** (Interface-Typ `ovpn`) erhöht den
  Empfangszähler des Kernels nie — `/proc/net/dev` und `ip -s link` zeigen
  dasselbe — deshalb steht dort `n/a` statt einer Null, und die Kurve zeichnet
  nur den Upload.
- **Profile** — alles, was das Backend kennt, mit Zustand; Klick verbindet oder
  wechselt, dazu Autostart, Zugangsdaten und Entfernen pro Profil. WireGuard
  listet `wg-quick`-Units und NetworkManager-Verbindungen nebeneinander und
  schaltet jede auf ihrem eigenen Weg. OpenVPN ebenso für `openvpn-client@`
  und NetworkManager-Verbindungen vom Typ `vpn` (service-type openvpn).
- **Import** — Datei über den Dialog wählen oder Pfad einfügen; das Widget
  erkennt selbst, ob OpenVPN oder WireGuard, schlägt einen Namen vor und
  installiert. Eine `.ovpn`-Datei bietet bis zu drei Ziele: NetworkManager
  (ohne Root-Helfer, und der Weg, der ein Einmalpasswort abfragen kann),
  den OpenVPN-3-Sitzungsmanager oder `/etc/openvpn/client` für
  `openvpn-client@`. GlobalProtect-Portale kommen stattdessen als Hostname
  dazu, sie sind ja keine Dateien.

## Voraussetzungen

Je nach Backend `openvpn`, `openvpn3` (openvpn3-linux), `wireguard-tools`
(für `wg-quick@`), NetworkManager ab 1.16 (für WireGuard-Verbindungen),
`networkmanager-openvpn` (für OpenVPN-Verbindungen in NetworkManager) oder
`globalprotect-openconnect`. Dazu `bash`, `systemctl`, `ip`, `journalctl`. Für den Dateidialog `zenity`, für die Profilverwaltung zusätzlich
`pkexec` und `python3`. Server und Cipher kommen aus dem Journal — ohne
Leserechte darauf steht dort schlicht `—`.

## Installieren

```bash
omarchy plugin add https://github.com/Nepomuk-Software/MultiVPN.git --enable
```

## Privilegien-Grenze

**Alles Lesende läuft ohne erhöhte Rechte.** Zustand, Durchsatz und Details
kommen aus unprivilegierten Abfragen. Schalten geht über `systemctl start/stop`
— dafür fragt polkit, sofern keine Regel existiert.

**Ausnahme ist die Profilverwaltung.** `/etc/openvpn/client` ist
`750 openvpn:network`, `/etc/wireguard` gehört root allein — Auflisten,
Importieren und Entfernen brauchen dort also root. WireGuard- und
OpenVPN-Verbindungen, die NetworkManager gehören, umgehen das komplett:
`nmcli` listet sie ohne Rechte, den Rest regelt Polkit. OpenVPN-3-Configs
umgehen es auf demselben Weg über das `openvpn3`-CLI.
Genau das richtet `system/install.sh` ein — als bewusst getrennter, manueller
Schritt. `omarchy plugin add` führt weder Installer noch `sudo` aus, und dieses
Plugin tut es auch nicht. Ohne den Helfer bleibt das Panel voll nutzbar, der
Profilteil sagt dann, was fehlt.

Dafür gibt es im Panel den Knopf **Set up profile management**. Er öffnet ein
Terminal und startet das Skript mit `sudo` — bewusst kein Passwortdialog: das
Skript liegt in einem Verzeichnis, das du beschreiben kannst, und ein
benutzerschreibbares Skript über `pkexec` zu starten ist eine
Rechteausweitung wie aus dem Lehrbuch. Im Terminal siehst du außerdem, was es
tut. Von Hand dasselbe:

```bash
sudo bash ~/.config/omarchy/plugins/io.github.nepomuk-software.multivpn/system/install.sh
```

Installiert werden `/usr/local/bin/multivpn-admin` (`root:root 0755`), die
Polkit-Aktion `software.nepomuk.multivpn.manage`, zwei systemd-Units, die den
Profil-Cache aktuell halten, und `/var/lib/multivpn/profiles.json`
(`root:wheel 0640`). Rückgängig mit `--uninstall`.

Zwei Details zum Helfer: Beim Import liest er die Quelldatei **mit den Rechten
des Aufrufers**, sonst könnte jeder, der ihn starten darf, beliebige
root-Dateien nach `/etc/openvpn/client` kopieren lassen. Und der Cache enthält
nur Name, Server, Port, Protokoll und ob Zugangsdaten hinterlegt sind — nie
Schlüsselmaterial oder Passwörter.

## WireGuard-Config installieren

Zwei Wege, beide bietet das Panel unter **Add config** an, sobald es eine
WireGuard-Datei erkennt:

- **NetworkManager** — kein Root-Helfer, kein `wireguard-tools`, keine
  Passwortabfrage. Das Kernel-Modul reicht, und NetworkManager aktiviert die
  Verbindung direkt nach dem Import. Von Hand:
  `nmcli connection import type wireguard file tunnel.conf`
- **wg-quick** — landet in `/etc/wireguard` und startet über
  `wg-quick@<name>.service`. Braucht das Paket `wireguard-tools`, damit es diese
  Unit überhaupt gibt, und den Root-Helfer zum Schreiben.

Danach taucht die Verbindung in der Liste auf und lässt sich wie jede andere
schalten.

## OpenVPN-Config installieren

Drei Wege unter **Add config**, sobald eine `.ovpn`-Datei erkannt ist. Die
unprivilegierten zuerst:

- **NetworkManager** — kein Root-Helfer. Braucht das Paket
  `networkmanager-openvpn`. Das ist der Weg, der ein Einmalpasswort
  abfragen kann (`static-challenge` oder eine Challenge vom Server): eine
  systemd-Unit hat kein TTY, und gespeicherte Zugangsdaten können keinen
  rotierenden Code halten. Von Hand:
  `nmcli connection import type openvpn file client.ovpn`
  Verbinden geht über `nmcli connection up`. Braucht das Profil eine
  Challenge oder fehlt ein NetworkManager-Secret-Agent — Omarchy bringt
  keinen mit — öffnet das Widget ein Terminal mit `nmcli --ask`.
  Autostart ist NetworkManagers eigenes Flag; bei einem Challenge-Profil
  scheitert es beim Boot, weil niemand das OTP eingeben kann.
- **OpenVPN 3** — landet im Sitzungsmanager des Benutzers. Kein Root-Helfer.
  Web-Login öffnet den Browser, wie bisher.
- **openvpn-client@** — landet in `/etc/openvpn/client`. Braucht den
  Root-Helfer. Benutzer/Passwort lassen sich speichern, ein OTP nicht.

Ein `tun`, den NetworkManager von allein hochgezogen hat, wird nicht aus
der Interface-Liste geraten: der Unified-Modus meldet nur Verbindungen,
die er benennen kann. Steht das Profil als NM-Zeile in der Liste, hängen
Adresse, Routen, Laufzeit und Durchsatz daran wie bei jeder anderen.

## Bedienung

| Ort | Aktion |
|---|---|
| Bar, links | Panel auf/zu |
| Bar, rechts | Tunnel an/aus |
| Bar, mitte | neu einlesen |
| Panel, Schalter in der Zeile | dieses VPN an/aus |
| Panel, Klick auf inaktive Zeile | verbinden |
| Panel, Klick auf aktive Zeile | Detailblock auf sie richten |
| Panel, `v` | Tunnel an/aus |
| Panel, `r` | alles neu einlesen |
| Panel, `n` | Config hinzufügen |
| Panel, ↑ ↓ / Enter | Profil wählen und verbinden |
| Panel, Esc | offenes Formular schließen, sonst Panel |

Tastenkombination in `~/.config/hypr/bindings.lua`:

```lua
o.bind("SUPER + ALT + V", "VPN toggle", "omarchy-shell io.github.nepomuk-software.multivpn toggleVpn")
```

## Einstellungen

`omarchy bar set io.github.nepomuk-software.multivpn <key> <value>` —
`backend` (`unified`, `openvpn`, `openvpn3`, `wireguard`, `globalprotect`), `profile`,
`intervalSec`, `showRate`, `highlightWhenConnected`, `hideWhenDisconnected`.
Unified braucht keine Einstellung; `profile` ist dort nur der Favorit für den
Rechtsklick.

Bekannte Lücke: `gpclient` schwärzt Hostnamen in seinem eigenen Log. Sind
mehrere Portale eingetragen, kann das Widget nicht sagen, welches verbunden
ist — es meldet dann GlobalProtect als verbunden, ohne eine Zeile zu markieren. Details in der [englischen README](README.md).

## Entwickeln

Änderungen an den `.qml`-Dateien erreichen eine bereits eingehängte Bar-Instanz
**nicht**, trotz `Local plugin changed, reloading` im Log. Nach jeder Änderung
`omarchy restart shell`.

## Lizenz

MIT — siehe [LICENSE](LICENSE). Plugins laufen unsandboxed im Omarchy-Shell-
Prozess; lies den Code, bevor du ihn installierst.
