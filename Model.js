// Formatting and parsing for the OpenVPN widget. Kept as plain JS so the QML
// side stays about presentation and this stays trivially readable.

.pragma library

var HISTORY_POINTS = 60

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

// One call for everything readable without root. `is-enabled` errors out on
// unknown instances, which the `|| true` swallows.
function statusScript(unit) {
  var u = shellQuote(unit)
  return [
    'u=' + u + ';',
    'printf "state=%s\\n" "$(systemctl is-active "$u" 2>/dev/null || true)";',
    'printf "enabled=%s\\n" "$(systemctl is-enabled "$u" 2>/dev/null || true)";',
    'printf "since=%s\\n" "$(date -d "$(systemctl show "$u" -p ActiveEnterTimestamp --value 2>/dev/null)" +%s 2>/dev/null || true)";',
    'i=$({ ip -brief link show type ovpn; ip -brief link show type tun; } 2>/dev/null |',
    '     awk \'NR==1 { sub(/@.*/, "", $1); print $1; exit }\');',
    'printf "iface=%s\\n" "${i:-}";',
    'if [ -n "$i" ]; then',
    '  printf "address=%s\\n" "$(ip -4 -brief addr show dev "$i" 2>/dev/null | awk \'{print $3}\' | cut -d/ -f1)";',
    '  printf "mtu=%s\\n" "$(cat /sys/class/net/"$i"/mtu 2>/dev/null || true)";',
    '  printf "routes=%s\\n" "$(ip -4 route show dev "$i" 2>/dev/null | awk \'{print $1}\' | grep -v "^default$" | paste -sd, -)";',
    'fi'
  ].join(" ")
}

// Server endpoint and cipher only exist in the journal. Runs rarely — when the
// panel opens and when a new connection comes up.
function detailScript(unit) {
  var u = shellQuote(unit)
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
function profileStateScript(names) {
  if (!names || names.length === 0) return "true"
  var quoted = []
  for (var i = 0; i < names.length; i++) quoted.push(shellQuote(names[i]))
  return 'for n in ' + quoted.join(" ") + '; do ' +
         'printf "%s=%s:%s\\n" "$n" ' +
         '"$(systemctl is-active "openvpn-client@$n.service" 2>/dev/null || true)" ' +
         '"$(systemctl is-enabled "openvpn-client@$n.service" 2>/dev/null || true)"; done'
}

function mergeProfiles(cached, stateRaw) {
  var states = parseKeyValues(stateRaw)
  var out = []
  for (var i = 0; i < cached.length; i++) {
    var p = cached[i]
    var parts = String(states[p.name] || ":").split(":")
    out.push({
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
