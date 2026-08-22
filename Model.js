// Formatting, parsing and the backend registry. Plain JS so the QML side stays
// about presentation and this stays trivially readable.

.pragma library

var HISTORY_POINTS = 60

// ── Backends ───────────────────────────────────────────────────────────────
//
// Roughly two thirds of this widget never cared which VPN it was looking at:
// address, MTU, routes, throughput and the sparkline all come off the tunnel
// interface. Only four things differ per backend — reading state, connecting,
// disconnecting, and enumerating profiles — so a backend is described by what
// it can do and by the script that reports its state.
//
// GlobalProtect is deliberately the thin one. gpclient has no status command,
// no systemd unit and an interactive SSO login, so the widget watches it and
// can take it down, but cannot own bringing it up.

var BACKENDS = {
  openvpn: {
    label: "OpenVPN",
    profileLabel: "Profile",
    canConnect: true,
    canDisconnect: true,
    canList: true,
    canAutostart: true,
    canCredentials: true,
    canImport: true,
    connectNeedsTerminal: false,
    hasCipher: true
  },
  wireguard: {
    label: "WireGuard",
    profileLabel: "Interface",
    canConnect: true,
    canDisconnect: true,
    canList: true,
    canAutostart: true,
    canCredentials: false,   // keys live in the config, there is nothing to type
    canImport: true,
    connectNeedsTerminal: false,
    hasCipher: false         // fixed Noise crypto, nothing to report
  },
  globalprotect: {
    label: "GlobalProtect",
    profileLabel: "Portal",
    canConnect: true,
    canDisconnect: true,
    canList: false,          // portals live in the GUI's own config
    canAutostart: false,     // no unit to enable
    canCredentials: false,   // SSO
    canImport: false,
    connectNeedsTerminal: true,
    hasCipher: false
  }
}

function backend(name) {
  return BACKENDS[name] || BACKENDS.openvpn
}

function backendNames() {
  return ["openvpn", "wireguard", "globalprotect"]
}

// ── Formatting ─────────────────────────────────────────────────────────────

function bytes(value) {
  var n = Number(value)
  if (!isFinite(n) || n < 0) return "—"
  var units = ["B", "kB", "MB", "GB", "TB"]
  var i = 0
  while (n >= 1024 && i < units.length - 1) { n /= 1024; i++ }
  return (i === 0 ? Math.round(n) : n.toFixed(n < 10 ? 1 : 0)) + " " + units[i]
}

// The bar label and the throughput row share this shape: compact, stable width.
function rate(bytesPerSecond) {
  var n = Number(bytesPerSecond)
  if (!isFinite(n) || n < 0) return "0"
  if (n < 1000) return Math.round(n) + ""
  var units = ["k", "M", "G"]
  var i = -1
  while (n >= 1000 && i < units.length - 1) { n /= 1000; i++ }
  return (n < 10 ? n.toFixed(1) : Math.round(n) + "") + units[i]
}

function duration(seconds) {
  var s = Math.max(0, Math.floor(Number(seconds) || 0))
  var d = Math.floor(s / 86400)
  var h = Math.floor((s % 86400) / 3600)
  var m = Math.floor((s % 3600) / 60)
  if (d > 0) return d + "d " + h + "h"
  if (h > 0) return h + "h " + m + "m"
  if (m > 0) return m + "m " + (s % 60) + "s"
  return s + "s"
}

function stateLabel(unitState, address, intent) {
  if (intent === "up") return "connecting…"
  if (intent === "down") return "disconnecting…"
  if (unitState === "activating") return "connecting…"
  if (unitState === "deactivating") return "disconnecting…"
  if (unitState === "active") return address ? "connected" : "bringing up tunnel…"
  if (unitState === "failed") return "failed"
  return "disconnected"
}

// ── Parsing ────────────────────────────────────────────────────────────────

// The scripts below emit "key=value" lines. Unknown keys are ignored so an
// extended script cannot break an older panel.
function parseKeyValues(raw) {
  var out = {}
  var lines = String(raw || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i]
    var eq = line.indexOf("=")
    if (eq <= 0) continue
    out[line.substring(0, eq)] = line.substring(eq + 1)
  }
  return out
}

function parseProfiles(raw) {
  try {
    var data = JSON.parse(String(raw || "").trim() || "{}")
    return Array.isArray(data.profiles) ? data.profiles : []
  } catch (e) {
    return []
  }
}

// systemd timestamps ("Sat 2026-08-22 14:01:14 CEST") are not reliably
// parseable by Date(), so we ask for Unix seconds and do the maths here.
function uptimeSeconds(sinceEpoch, nowMs) {
  var since = Number(sinceEpoch)
  if (!isFinite(since) || since <= 0) return 0
  return Math.max(0, Math.floor(nowMs / 1000) - since)
}

// ── Commands ───────────────────────────────────────────────────────────────

function shellQuote(value) {
  return "'" + String(value === undefined || value === null ? "" : value).replace(/'/g, "'\\''") + "'"
}

// Everything downstream of "which interface is the tunnel on" is identical for
// every backend, so it lives in one place and gets appended to each status
// script. `iface` must already be set when this runs.
var INTERFACE_SNIPPET = [
  'printf "iface=%s\\n" "${iface:-}";',
  'if [ -n "${iface:-}" ]; then',
  '  printf "address=%s\\n" "$(ip -4 -brief addr show dev "$iface" 2>/dev/null | awk \'{print $3}\' | cut -d/ -f1)";',
  '  printf "mtu=%s\\n" "$(cat /sys/class/net/"$iface"/mtu 2>/dev/null || true)";',
  '  printf "routes=%s\\n" "$(ip -4 route show dev "$iface" 2>/dev/null | awk \'{print $1}\' | grep -v "^default$" | paste -sd, -)";',
  'fi'
].join(" ")

// Picks the first tunnel-ish device. OpenVPN 2.7 with DCO creates type "ovpn",
// without DCO "tun"; openconnect/GlobalProtect always uses "tun".
var FIRST_TUN = '$({ ip -brief link show type ovpn; ip -brief link show type tun; } 2>/dev/null | ' +
                'awk \'NR==1 { sub(/@.*/, "", $1); print $1; exit }\')'

function openvpnStatusScript(profile) {
  var u = shellQuote("openvpn-client@" + profile + ".service")
  return [
    'u=' + u + ';',
    'printf "state=%s\\n" "$(systemctl is-active "$u" 2>/dev/null || true)";',
    'printf "enabled=%s\\n" "$(systemctl is-enabled "$u" 2>/dev/null || true)";',
    'printf "since=%s\\n" "$(date -d "$(systemctl show "$u" -p ActiveEnterTimestamp --value 2>/dev/null)" +%s 2>/dev/null || true)";',
    'iface=' + FIRST_TUN + ';',
    INTERFACE_SNIPPET
  ].join(" ")
}

// WireGuard comes in two flavours on the same machine: wg-quick units reading
// /etc/wireguard, and connections NetworkManager owns. Probe the unit first —
// if the config exists, wg-quick is what the user set up — then fall back to
// NetworkManager, and report which one answered so actions can match.
function wireguardStatusScript(name) {
  var n = shellQuote(name)
  var u = shellQuote("wg-quick@" + name + ".service")
  return [
    'n=' + n + '; u=' + u + '; origin=""; state=""; enabled=""; since=""; iface="";',
    'if systemctl cat "$u" >/dev/null 2>&1; then',
    '  state=$(systemctl is-active "$u" 2>/dev/null || true);',
    '  if [ "$state" != "inactive" ] || [ -e /sys/class/net/"$n" ]; then',
    '    origin=wg-quick;',
    '    enabled=$(systemctl is-enabled "$u" 2>/dev/null || true);',
    '    since=$(date -d "$(systemctl show "$u" -p ActiveEnterTimestamp --value 2>/dev/null)" +%s 2>/dev/null || true);',
    '    [ "$state" = active ] && iface="$n";',
    '  fi;',
    'fi;',
    'if [ -z "$origin" ] && command -v nmcli >/dev/null 2>&1; then',
    '  row=$(nmcli -t -f NAME,TYPE,DEVICE,STATE connection show 2>/dev/null |',
    '        awk -F: -v n="$n" \'$1 == n && $2 == "wireguard" { print; exit }\');',
    '  if [ -n "$row" ]; then',
    '    origin=nm;',
    '    dev=$(printf "%s" "$row" | cut -d: -f3);',
    '    st=$(printf "%s" "$row" | cut -d: -f4);',
    '    [ "$st" = activated ] && state=active || state=inactive;',
    '    [ "$state" = active ] && iface="$dev";',
    '    a=$(nmcli -g connection.autoconnect connection show "$n" 2>/dev/null || true);',
    '    [ "$a" = yes ] && enabled=enabled || enabled=disabled;',
    '    since=$(nmcli -g connection.timestamp connection show "$n" 2>/dev/null || true);',
    '  fi;',
    'fi;',
    'printf "origin=%s\\n" "${origin:-}";',
    'printf "state=%s\\n" "${state:-inactive}";',
    'printf "enabled=%s\\n" "${enabled:-}";',
    'printf "since=%s\\n" "${since:-}";',
    INTERFACE_SNIPPET
  ].join(" ")
}

// gpclient has no status command and no unit, so presence of the process is
// the signal. /run/gpclient.lock alone is not enough — a lock file can outlive
// the process that held it.
function globalprotectStatusScript() {
  return [
    'pid=$(pgrep -x gpclient 2>/dev/null | head -1);',
    '[ -z "$pid" ] && pid=$(pgrep -x gpservice 2>/dev/null | head -1);',
    'iface=' + FIRST_TUN + ';',
    'if [ -n "$pid" ]; then',
    '  if [ -n "$iface" ]; then state=active; else state=activating; fi;',
    '  et=$(ps -o etimes= -p "$pid" 2>/dev/null | tr -d " ");',
    '  [ -n "$et" ] && printf "since=%s\\n" "$(( $(date +%s) - et ))";',
    'else',
    '  state=inactive; iface="";',
    'fi;',
    'printf "state=%s\\n" "$state";',
    'printf "enabled=%s\\n" "";',
    INTERFACE_SNIPPET
  ].join(" ")
}

function statusScript(backendName, profile) {
  if (backendName === "wireguard") return wireguardStatusScript(profile)
  if (backendName === "globalprotect") return globalprotectStatusScript()
  return openvpnStatusScript(profile)
}

// Server endpoint and cipher only exist in OpenVPN's journal. Runs rarely —
// when the panel opens and when a new connection comes up.
function detailScript(backendName, profile) {
  if (backendName !== "openvpn") return 'true'
  var u = shellQuote("openvpn-client@" + profile + ".service")
  return [
    'log=$(journalctl -u ' + u + ' -n 400 --no-pager -o cat 2>/dev/null);',
    'printf "server=%s\\n" "$(printf "%s" "$log" |',
    '  grep -oE "Peer Connection Initiated with \\[AF_INET[6]?\\][^ ]+" | tail -1 |',
    '  sed -E "s/.*\\]//")";',
    'printf "cipher=%s\\n" "$(printf "%s" "$log" |',
    '  grep -oE "Data Channel: (cipher|using cipher) .[A-Za-z0-9-]+." | tail -1 |',
    '  grep -oE "[A-Z][A-Z0-9-]{3,}")"'
  ].join(" ")
}

// State of every known profile in one go — one "name=active:enabled" line each.
// wg-quick and OpenVPN both answer through systemd; NetworkManager profiles
// are asked separately and merged in.
function profileStateScript(entries) {
  if (!entries || entries.length === 0) return "true"
  var lines = []
  for (var i = 0; i < entries.length; i++) {
    var e = entries[i]
    var n = shellQuote(e.name)
    if (e.origin === "nm") {
      lines.push(
        'row=$(nmcli -t -f NAME,DEVICE,STATE connection show 2>/dev/null | awk -F: -v n=' + n + ' \'$1 == n { print; exit }\'); ' +
        'st=$(printf "%s" "$row" | cut -d: -f3); ' +
        'a=$(nmcli -g connection.autoconnect connection show ' + n + ' 2>/dev/null || true); ' +
        'printf "%s=%s:%s\\n" ' + n + ' "$([ "$st" = activated ] && echo active || echo inactive)" ' +
        '"$([ "$a" = yes ] && echo enabled || echo disabled)"')
    } else {
      var unit = e.backend === "wireguard" ? "wg-quick@" : "openvpn-client@"
      var u = shellQuote(unit + e.name + ".service")
      lines.push(
        'printf "%s=%s:%s\\n" ' + n + ' ' +
        '"$(systemctl is-active ' + u + ' 2>/dev/null || true)" ' +
        '"$(systemctl is-enabled ' + u + ' 2>/dev/null || true)"')
    }
  }
  return lines.join("; ")
}

// NetworkManager owns its own WireGuard connections, so they are listed live
// rather than through the privileged cache.
function nmWireguardListScript() {
  return 'command -v nmcli >/dev/null 2>&1 || exit 0; ' +
         'nmcli -t -f NAME,TYPE connection show 2>/dev/null | awk -F: \'$2 == "wireguard" { print $1 }\' | ' +
         'while IFS= read -r n; do ' +
         '  printf "%s\\t%s\\n" "$n" "$(nmcli -g wireguard.peers connection show "$n" 2>/dev/null | ' +
         '    grep -oE "endpoint = [^,]+" | head -1 | sed "s/endpoint = //")"; ' +
         'done'
}

function parseNmProfiles(raw) {
  var out = []
  var lines = String(raw || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    if (!lines[i]) continue
    var parts = lines[i].split("\t")
    if (!parts[0]) continue
    var endpoint = String(parts[1] || "")
    var host = endpoint, port = ""
    var colon = endpoint.lastIndexOf(":")
    if (colon > 0) { host = endpoint.substring(0, colon); port = endpoint.substring(colon + 1) }
    out.push({
      backend: "wireguard",
      origin: "nm",
      name: parts[0],
      remote: host,
      port: port,
      proto: "wireguard",
      hasAuth: true
    })
  }
  return out
}

function mergeProfiles(cached, nmProfiles, stateRaw, backendName) {
  var states = parseKeyValues(stateRaw)
  var all = (cached || []).concat(nmProfiles || [])
  var out = []
  for (var i = 0; i < all.length; i++) {
    var p = all[i]
    if (backendName && (p.backend || "openvpn") !== backendName) continue
    var parts = String(states[p.name] || ":").split(":")
    out.push({
      backend: p.backend || "openvpn",
      origin: p.origin || (p.backend === "wireguard" ? "wg-quick" : "systemd"),
      name: p.name,
      remote: p.remote || "",
      port: p.port || "",
      proto: p.proto || "",
      hasAuth: p.hasAuth === true,
      state: parts[0] || "inactive",
      autostart: parts[1] === "enabled"
    })
  }
  return out
}
