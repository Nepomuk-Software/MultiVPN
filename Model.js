// Formatting, parsing and the backend registry. Plain JS so the QML side stays
// about presentation and this stays trivially readable.

.pragma library

var HISTORY_POINTS = 60

// Profile names, endpoints, routes and journal text are read off the machine
// and out of files this widget does not write, then handed to QML and to a
// helper. Two ceilings apply to all of it.
//
// A byte ceiling, because nothing here is bounded by anything else: a config
// dropped into /etc/openvpn/client, a cache rewritten by hand, or a journal
// that has been talked at can all be arbitrarily large, and this runs inside
// the process that draws the desktop. Commands are capped by head(1) where they
// are built and again by clamp() where they are parsed.
//
// And a plain-text ceiling, because Qt's Text defaults to AutoText and renders
// what looks like markup as markup. Text sinks this plugin owns are set to
// PlainText; the ones it borrows from qs.Ui get their string through plain()
// first, which strips the characters that trigger the guess.
var MAX_OUTPUT = 262144   // bytes accepted from one command
var MAX_FIELD = 512       // characters kept for one displayed value
var MAX_PATH = 4096       // PATH_MAX: a path must not be silently shortened

function clamp(raw, max) {
  var s = String(raw === undefined || raw === null ? "" : raw)
  var cap = max || MAX_OUTPUT
  return s.length > cap ? s.substring(0, cap) : s
}

function plain(value, max) {
  return String(value === undefined || value === null ? "" : value)
    .replace(/[\u0000-\u0008\u000b-\u001f\u007f]/g, "")
    .replace(/[<>&]/g, "")
    .substring(0, max || MAX_FIELD)
}

// Every script this file builds ends up in a StdioCollector, which buffers
// whatever it is given. One wrapper so no script can forget its ceiling.
//
// The exit status needs carrying across the pipe by hand. A pipeline reports
// head's status, which is always 0, and the NetworkManager import reads that
// status to decide whether it worked — left alone, every failed import would
// report as a success. PIPESTATUS[0] is the group's own status. 141 is the
// group being killed by SIGPIPE because head had seen enough, which is this
// wrapper's doing rather than the command's failure, so it reads as success.
function capped(script) {
  return "{ " + script + " ; } | head -c " + MAX_OUTPUT
       + "; s=${PIPESTATUS[0]}; [ \"$s\" = 141 ] && s=0; exit \"$s\""
}

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
  // One widget for everything on the machine. Capabilities here are the union;
  // per row the panel asks capsFor(profile.backend) instead, so a GlobalProtect
  // portal in the list does not grow an autostart button it cannot honour.
  unified: {
    label: "VPN",
    profileLabel: "Connection",
    canConnect: true,
    canDisconnect: true,
    canList: true,
    canAutostart: true,
    canCredentials: true,
    canImport: true,
    canPortals: true,
    connectNeedsTerminal: false,
    hasCipher: true,
    unified: true
  },
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
  return ["unified", "openvpn", "wireguard", "globalprotect"]
}

// In unified mode every row can come from a different backend, so controls are
// decided per row rather than per widget.
function capsFor(profileBackend) {
  return BACKENDS[profileBackend] || BACKENDS.openvpn
}

function backendBadge(profile) {
  if (!profile) return ""
  if (profile.backend === "wireguard")
    return profile.origin === "nm" ? "WireGuard · NM" : "WireGuard"
  return backend(profile.backend).label
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
  var lines = clamp(raw).split("\n")
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
    var data = JSON.parse(clamp(raw).trim() || "{}")
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

// Unified mode asks the machine what is up — and accepts that more than one
// thing can be. Split-tunnel VPNs coexist happily; only full-tunnel configs
// fight, and then only over the default route, which the panel points out
// rather than preventing.
//
// Every active connection is emitted as one line:
//   conn=backend|origin|name|iface|since|enabled|address|mtu|routes
// Routes keep their "default" entry here; the panel hides it from the list but
// needs it to spot two tunnels claiming the default route.
function unifiedStatusScript() {
  return capped([
    'claimed=" ";',
    'emit() {',
    '  a=""; m=""; r=""; k="";',
    '  if [ -n "$4" ] && [ -e /sys/class/net/"$4" ]; then',
    '    a=$(ip -4 -brief addr show dev "$4" 2>/dev/null | awk \'{print $3}\' | cut -d/ -f1);',
    '    m=$(cat /sys/class/net/"$4"/mtu 2>/dev/null);',
    '    r=$(ip -4 route show dev "$4" 2>/dev/null | awk \'{print $1}\' | paste -sd, -);',
    '    k=$(ip -d link show "$4" 2>/dev/null |',
    '        awk \'$1=="ovpn"||$1=="wireguard"||$1=="tun"||$1=="tap"||$1=="ppp"{print $1; exit}\');',
    '  fi;',
    '  printf "conn=%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\\n" "$1" "$2" "$3" "$4" "$5" "$6" "$a" "$m" "$r" "$k";',
    '  [ -n "$4" ] && claimed="$claimed$4 ";',
    '};',

    // OpenVPN: several instances can run at once, and each one names its own
    // interface in its journal — "first tun device" would be a coin flip.
    'while IFS= read -r u; do',
    '  [ -z "$u" ] && continue;',
    '  n=${u#openvpn-client@}; n=${n%.service};',
    '  i=$(journalctl -u "$u" -n 200 --no-pager -o cat 2>/dev/null |',
    '      grep -oE "net_iface_new: add [^ ]+" | tail -1 | awk \'{print $3}\');',
    '  s=$(date -d "$(systemctl show "$u" -p ActiveEnterTimestamp --value 2>/dev/null)" +%s 2>/dev/null);',
    '  e=$(systemctl is-enabled "$u" 2>/dev/null);',
    '  emit openvpn systemd "$n" "$i" "$s" "$e";',
    'done < <(systemctl list-units "openvpn-client@*.service" --state=active --no-legend --plain 2>/dev/null | awk \'{print $1}\');',

    'while IFS= read -r u; do',
    '  [ -z "$u" ] && continue;',
    '  n=${u#wg-quick@}; n=${n%.service};',
    '  s=$(date -d "$(systemctl show "$u" -p ActiveEnterTimestamp --value 2>/dev/null)" +%s 2>/dev/null);',
    '  e=$(systemctl is-enabled "$u" 2>/dev/null);',
    '  emit wireguard wg-quick "$n" "$n" "$s" "$e";',
    'done < <(systemctl list-units "wg-quick@*.service" --state=active --no-legend --plain 2>/dev/null | awk \'{print $1}\');',

    'if command -v nmcli >/dev/null 2>&1; then',
    '  bs=$(printf "\\134");',
    '  while IFS= read -r escaped; do',
    '    [ -z "$escaped" ] && continue;',
    '    n=${escaped//"$bs"/};',
    '    d=$(nmcli -g GENERAL.DEVICES connection show "$n" 2>/dev/null | head -1);',
    '    s=$(nmcli -g connection.timestamp connection show "$n" 2>/dev/null);',
    '    a=$(nmcli -g connection.autoconnect connection show "$n" 2>/dev/null);',
    '    [ "$a" = yes ] && e=enabled || e=disabled;',
    '    emit wireguard nm "$n" "$d" "$s" "$e";',
    '  done < <(nmcli -t -f NAME,TYPE connection show --active 2>/dev/null | sed -n "s/:wireguard$//p");',
    'fi;',

    // GlobalProtect owns no unit and no name, so it gets whatever tunnel device
    // nothing else has claimed.
    'pid=$(pgrep -x gpclient 2>/dev/null | head -1);',
    '[ -z "$pid" ] && pid=$(pgrep -x gpservice 2>/dev/null | head -1);',
    'if [ -n "$pid" ]; then',
    '  gi="";',
    '  for cand in $({ ip -brief link show type ovpn; ip -brief link show type tun; } 2>/dev/null |',
    '                awk \'{ sub(/@.*/, "", $1); print $1 }\'); do',
    '    case "$claimed" in *" $cand "*) ;; *) gi="$cand"; break;; esac;',
    '  done;',
    '  et=$(ps -o etimes= -p "$pid" 2>/dev/null | tr -d "[:space:]");',
    '  gs="";',
    '  [ -n "$et" ] && gs=$(( $(date +%s) - et ));',
    '  emit globalprotect process "" "$gi" "$gs" "";',
    'fi'
  ].join(" "))
}

// One "conn=" line into an object. Unknown or short lines are dropped rather
// than producing half-filled entries.
function parseConnections(raw) {
  var out = []
  var lines = clamp(raw).split("\n")
  for (var i = 0; i < lines.length; i++) {
    if (lines[i].indexOf("conn=") !== 0) continue
    var f = lines[i].substring(5).split("|")
    if (f.length < 9) continue
    var routes = f[8] ? f[8].split(",").filter(function(r) { return r !== "" }) : []
    out.push({
      kind: f[9] || "",
      backend: f[0],
      origin: f[1],
      name: f[2],
      iface: f[3],
      since: Number(f[4] || 0),
      enabled: f[5],
      address: f[6],
      mtu: f[7],
      routes: routes,
      hasDefaultRoute: routes.indexOf("default") !== -1
    })
  }
  return out
}

// What this machine can actually do. Without this the panel says "VPN" and
// leaves you guessing which of the three it even covers here.
function availabilityScript() {
  return capped([
    'have() { command -v "$1" >/dev/null 2>&1 && echo 1 || echo 0; };',
    'printf "openvpn=%s\\n" "$(have openvpn)";',
    'printf "wgquick=%s\\n" "$(have wg-quick)";',
    'printf "nmcli=%s\\n" "$(have nmcli)";',
    'printf "globalprotect=%s\\n" "$(have gpclient)";',
    'printf "zenity=%s\\n" "$(have zenity)"'
  ].join(" "))
}

// Human summary for the panel header.
function availabilityLabel(av) {
  var found = []
  if (av.openvpn === "1") found.push("OpenVPN")
  if (av.wgquick === "1" || av.nmcli === "1") found.push("WireGuard")
  if (av.globalprotect === "1") found.push("GlobalProtect")
  if (found.length === 0) return "no VPN tooling found"
  return found.join(" · ") + " available"
}

// One probe for every mode. Pinning the widget to a single backend is a filter
// over its result, not a second way of asking.
function statusScript() {
  return unifiedStatusScript()
}

// Server endpoint and cipher only exist in OpenVPN's journal. Runs rarely —
// when the panel opens and when a new connection comes up.
function detailScript(backendName, profile) {
  if (backendName !== "openvpn") return 'true'
  var u = shellQuote("openvpn-client@" + profile + ".service")
  return capped([
    'log=$(journalctl -u ' + u + ' -n 400 --no-pager -o cat 2>/dev/null);',
    'printf "server=%s\\n" "$(printf "%s" "$log" |',
    '  grep -oE "Peer Connection Initiated with \\[AF_INET[6]?\\][^ ]+" | tail -1 |',
    '  sed -E "s/.*\\]//")";',
    'printf "cipher=%s\\n" "$(printf "%s" "$log" |',
    '  grep -oE "Data Channel: (cipher|using cipher) .[A-Za-z0-9-]+." | tail -1 |',
    '  grep -oE "[A-Z][A-Z0-9-]{3,}")"'
  ].join(" "))
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
        'st=$(nmcli -g GENERAL.STATE connection show ' + n + ' 2>/dev/null || true); ' +
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
  return capped(lines.join("; "))
}

// NetworkManager owns its own WireGuard connections, so they are listed live
// rather than through the privileged cache.
// nmcli's terse output escapes colons inside values, so connection names are
// filtered by stripping the trailing ":wireguard" rather than splitting on ":".
// Peer lines read "endpoint=host:port allowed-ips=..." with the port's colon
// backslash-escaped and no spaces around the equals sign.
function nmWireguardListScript() {
  return capped([
    'command -v nmcli >/dev/null 2>&1 || exit 0;',
    // A literal backslash through JS, bash and sed is a quoting swamp, so the
    // unescaping uses parameter expansion against a backslash built from its
    // octal code. The expansion must be quoted: unquoted, a lone backslash is
    // read as a pattern escape and matches nothing.
    'bs=$(printf "\\134");',
    'nmcli -t -f NAME,TYPE connection show 2>/dev/null | sed -n "s/:wireguard$//p" |',
    'while IFS= read -r escaped; do',
    '  n=${escaped//"$bs"/};',
    '  peers=$(nmcli -g wireguard.peers connection show "$n" 2>/dev/null | head -1);',
    '  ep=$(printf "%s" "$peers" | grep -oE "endpoint=[^ ]+" | head -1);',
    '  ep=${ep#endpoint=}; ep=${ep//"$bs"/};',
    '  ai=$(printf "%s" "$peers" | grep -oE "allowed-ips=[^ ]+" | head -1);',
    '  ai=${ai#allowed-ips=}; ai=${ai//"$bs"/};',
    '  printf "%s\\t%s\\t%s\\n" "$n" "$ep" "$ai";',
    'done'
  ].join(" "))
}

function parseNmProfiles(raw) {
  var out = []
  var lines = clamp(raw).split("\n")
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
      allowedIps: String(parts[2] || ""),
      hasAuth: true
    })
  }
  return out
}

// GlobalProtect portals have no system-wide registry, so the widget keeps its
// own list under ~/.local/state. They are plain hostnames, nothing secret.
function portalProfiles(portals) {
  var out = []
  for (var i = 0; i < (portals || []).length; i++) {
    var name = String(portals[i] || "").trim()
    if (!name) continue
    out.push({
      backend: "globalprotect",
      origin: "process",
      name: name,
      remote: name,
      port: "",
      proto: "gp",
      hasAuth: true,
      state: "inactive",
      autostart: false
    })
  }
  return out
}

// Which kind of config the user just picked, so import does not need the user
// to know. Checked on the head of the file only — inline certificates make
// these files large and the markers are always near the top.
function detectKindScript(path) {
  var q = shellQuote(path)
  return capped('c=$(head -c 8192 ' + q + ' 2>/dev/null); ' +
         'if printf "%s" "$c" | grep -qi "^\\[Interface\\]"; then echo wireguard; ' +
         'elif printf "%s" "$c" | grep -qE "^[[:space:]]*remote "; then echo openvpn; ' +
         'else echo unknown; fi')
}

// NetworkManager imports a wg-quick config file directly, with no root helper
// and no wireguard-tools — the kernel module is all it needs. That makes it the
// path of least resistance for WireGuard, so the panel offers it first.
// nmcli names the connection after the file, hence the rename.
function nmImportScript(path, name) {
  var f = shellQuote(path)
  var n = shellQuote(name)
  return capped([
    'out=$(nmcli connection import type wireguard file ' + f + ' 2>&1) || {',
    '  printf "%s" "$out" >&2; exit 1;',
    '};',
    'id=$(printf "%s" "$out" | sed -n "s/^Connection .\\(.*\\). (.*/\\1/p");',
    'if [ -n "$id" ] && [ "$id" != ' + n + ' ]; then',
    '  nmcli connection modify "$id" connection.id ' + n + ' >/dev/null 2>&1 || true;',
    'fi'
  ].join(" "))
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
      allowedIps: p.allowedIps || "",
      state: parts[0] || "inactive",
      autostart: parts[1] === "enabled"
    })
  }
  return out
}
