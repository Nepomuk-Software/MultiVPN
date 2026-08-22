import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

// All state for the OpenVPN widget. The panel only reads from here and calls
// actions, which keeps presentation free of process plumbing.
//
// Privilege model: reading needs no root at all (systemctl is-active/is-enabled,
// /sys/class/net, the journal). Writing goes through pkexec and the helper at
// /usr/local/bin/omarchy-vpn-admin. The profile list comes from that helper's
// cache so merely opening the panel never raises an auth dialog.
Item {
  id: root

  property var settings: ({})
  property bool detailed: false        // panel open → poll faster, fetch details

  readonly property string helperPath: "/usr/local/bin/omarchy-vpn-admin"
  readonly property string cachePath: "/var/lib/omarchy-vpn/profiles.json"

  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  readonly property string profile: {
    var raw = String(setting("profile", "work"))
    return /^[A-Za-z0-9._-]+$/.test(raw) ? raw : "work"
  }
  readonly property int intervalSec: Math.max(1, Number(setting("intervalSec", 5)))
  readonly property bool showRate: setting("showRate", false) === true
  readonly property string unit: "openvpn-client@" + profile + ".service"

  // ── Connection state ─────────────────────────────────────────────────────
  property string unitState: "unknown"
  property string enabledState: ""
  property string iface: ""
  property string address: ""
  property string mtu: ""
  property string server: ""
  property string cipher: ""
  property var routes: []
  property int since: 0                // Unix seconds, ActiveEnterTimestamp
  property string intent: ""           // "" | "up" | "down"
  property string actionStatus: ""
  property string lastError: ""
  property bool helperInstalled: false

  readonly property bool connected: unitState === "active" && address !== ""
  readonly property bool failed: unitState === "failed"
  readonly property bool busy: intent !== "" || unitState === "activating"
                               || unitState === "deactivating"
                               || (unitState === "active" && address === "")
  readonly property bool autostart: enabledState === "enabled"
  readonly property string stateLabel: Model.stateLabel(unitState, address, intent)

  property int uptimeSeconds: 0

  // ── Throughput ───────────────────────────────────────────────────────────
  property real rxBytes: 0
  property real txBytes: 0
  property real rxRate: 0
  property real txRate: 0
  property var history: []             // [{rx, tx}], newest last
  property real peakRate: 1

  property real _lastRx: -1
  property real _lastTx: -1
  property real _lastAt: 0

  // ── Profiles ─────────────────────────────────────────────────────────────
  property var cachedProfiles: []
  property string profileStates: ""
  readonly property var profiles: Model.mergeProfiles(cachedProfiles, profileStates)

  signal actionFinished(string command, bool ok, string message)

  // ── Actions ──────────────────────────────────────────────────────────────

  function refresh() { if (!statusProc.running) statusProc.running = true }

  function refreshDetails() { if (!detailProc.running) detailProc.running = true }

  function refreshProfiles() {
    if (!cacheProc.running) cacheProc.running = true
    if (!profileStateProc.running) profileStateProc.running = true
  }

  function toggle() {
    unitState === "active" || unitState === "activating" ? disconnect() : connect()
  }

  function connect(name) { switchTo(name || profile, "up") }

  function disconnect() {
    if (intent !== "") return
    intent = "down"
    actionStatus = ""
    unitAction.targetUnit = unit
    unitAction.running = true
  }

  // Connecting a different profile means taking the running one down first.
  // Two tunnels at once would be a routing brawl.
  function switchTo(name, direction) {
    if (intent !== "") return
    intent = direction || "up"
    actionStatus = ""
    lastError = ""
    unitAction.targetUnit = "openvpn-client@" + name + ".service"
    unitAction.running = true
  }

  function setAutostart(name, on) { admin(["autostart", name, on ? "on" : "off"], "autostart") }

  function importConfig(sourcePath, name) { admin(["import", sourcePath, name], "import") }

  function removeProfile(name) { admin(["remove", name], "remove") }

  function setCredentials(name, user, password) {
    if (!helperInstalled) { lastError = helperMissing; return }
    credentialsProc.secret = user + "\n" + password + "\n"
    credentialsProc.command = ["pkexec", helperPath, "credentials", name]
    actionStatus = "Setting credentials…"
    credentialsProc.running = true
  }

  function pickConfigFile() { if (!filePicker.running) filePicker.running = true }

  readonly property string helperMissing:
    "Helper not installed — run system/install.sh from the plugin directory"

  // Every writing action goes through pkexec: one auth dialog, after which
  // polkit keeps the grant open briefly (auth_admin_keep).
  function admin(args, label) {
    if (adminProc.running) return
    if (!helperInstalled) { lastError = helperMissing; return }
    adminProc.label = label
    adminProc.command = ["pkexec", helperPath].concat(args)
    actionStatus = label === "import" ? "Importing config…"
                 : label === "remove" ? "Removing profile…"
                 : "Setting autostart…"
    lastError = ""
    adminProc.running = true
  }

  function applyStatus(raw) {
    var kv = Model.parseKeyValues(raw)
    unitState = kv.state || "unknown"
    enabledState = kv.enabled || ""
    iface = kv.iface || ""
    address = kv.address || ""
    mtu = kv.mtu || ""
    since = Number(kv.since || 0)
    routes = kv.routes ? String(kv.routes).split(",").filter(function(r) { return r !== "" }) : []
    uptimeSeconds = Model.uptimeSeconds(since, Date.now())

    // No tunnel, nothing to count. Reset counters and the curve, otherwise the
    // next session starts with a jump out of the previous one.
    if (!iface) resetStats()
  }

  function resetStats() {
    rxBytes = 0; txBytes = 0; rxRate = 0; txRate = 0
    _lastRx = -1; _lastTx = -1; _lastAt = 0
    history = []
    peakRate = 1
  }

  function applyStats(raw) {
    var parts = String(raw || "").trim().split(/\s+/)
    if (parts.length < 2) return
    var rx = Number(parts[0]), tx = Number(parts[1])
    if (!isFinite(rx) || !isFinite(tx)) return

    var now = Date.now()
    if (_lastAt > 0 && rx >= _lastRx && tx >= _lastTx) {
      var dt = (now - _lastAt) / 1000
      if (dt > 0.2) {
        rxRate = (rx - _lastRx) / dt
        txRate = (tx - _lastTx) / dt
        pushHistory(rxRate, txRate)
      }
    }
    rxBytes = rx; txBytes = tx
    _lastRx = rx; _lastTx = tx; _lastAt = now
  }

  function pushHistory(rx, tx) {
    var next = history.slice(-(Model.HISTORY_POINTS - 1))
    next.push({ rx: rx, tx: tx })
    history = next

    var peak = 1
    for (var i = 0; i < next.length; i++)
      peak = Math.max(peak, next[i].rx, next[i].tx)
    peakRate = peak
  }

  // ── Processes ────────────────────────────────────────────────────────────

  Process {
    id: statusProc
    command: ["bash", "-lc", Model.statusScript(root.unit)]
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.applyStatus(text) }
  }

  Process {
    id: detailProc
    command: ["bash", "-lc", Model.detailScript(root.unit)]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var kv = Model.parseKeyValues(text)
        root.server = kv.server || ""
        root.cipher = kv.cipher || ""
      }
    }
  }

  // Two numbers out of sysfs, no shell. Runs once a second while someone is
  // looking, so it is kept as cheap as it can be.
  Process {
    id: statsProc
    command: ["cat",
              "/sys/class/net/" + root.iface + "/statistics/rx_bytes",
              "/sys/class/net/" + root.iface + "/statistics/tx_bytes"]
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.applyStats(text) }
  }

  Process {
    id: cacheProc
    command: ["cat", root.cachePath]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.cachedProfiles = Model.parseProfiles(text)
    }
  }

  Process {
    id: profileStateProc
    command: ["bash", "-lc", Model.profileStateScript(
      root.cachedProfiles.map(function(p) { return p.name }))]
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.profileStates = text }
  }

  Process {
    id: helperProc
    command: ["test", "-x", root.helperPath]
    onExited: function(code) { root.helperInstalled = code === 0 }
  }

  // openvpn-client@.service is Type=notify, so systemctl blocks until the
  // tunnel reports or fails — the exit code already is the result.
  Process {
    id: unitAction
    property string targetUnit: ""
    command: ["systemctl", root.intent === "down" ? "stop" : "start", targetUnit]
    onExited: function(code) {
      var wasUp = root.intent === "up"
      root.intent = ""
      root.refresh()
      if (code === 0) {
        root.actionStatus = ""
        root.lastError = ""
        root.refreshDetails()
        root.actionFinished("unit", true, wasUp ? "connected" : "disconnected")
      } else {
        root.actionFinished("unit", false, wasUp ? "connection failed" : "disconnect failed")
        if (wasUp) reasonProc.running = true
        else root.lastError = "Disconnect failed"
      }
    }
  }

  // When bringing the tunnel up fails, the reason is in the journal.
  Process {
    id: reasonProc
    command: ["bash", "-lc",
      "journalctl -u " + Model.shellQuote(root.unit) + " -n 40 --no-pager -o cat 2>/dev/null | " +
      "grep -oE 'AUTH_FAILED|TLS Error|Connection refused|Cannot open' | tail -1"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var why = String(text || "").trim()
        root.lastError = "Connection failed" + (why ? ": " + why : "")
      }
    }
  }

  Process {
    id: adminProc
    property string label: ""
    stdout: StdioCollector { waitForEnd: true }
    stderr: StdioCollector { waitForEnd: true }
    onExited: function(code) {
      root.actionStatus = ""
      if (code === 0) {
        root.lastError = ""
        root.refreshProfiles()
        root.refresh()
        root.actionFinished(label, true, String(stdout.text || "").trim())
      } else if (code === 126 || code === 127) {
        // pkexec: dismissed or not authorised.
        root.actionFinished(label, false, "cancelled")
      } else {
        root.lastError = String(stderr.text || "").trim() || "Action failed"
        root.actionFinished(label, false, root.lastError)
      }
    }
  }

  Process {
    id: credentialsProc
    property string secret: ""
    stdinEnabled: true
    stderr: StdioCollector { waitForEnd: true }
    onStarted: { write(secret); secret = "" }
    onExited: function(code) {
      root.actionStatus = ""
      if (code === 0) {
        root.lastError = ""
        root.refreshProfiles()
        root.actionFinished("credentials", true, "credentials set")
      } else {
        root.lastError = String(stderr.text || "").trim() || "Could not set credentials"
        root.actionFinished("credentials", false, root.lastError)
      }
    }
  }

  // zenity ships with Omarchy and is the only file dialog involved.
  Process {
    id: filePicker
    command: ["zenity", "--file-selection", "--title=Select an OpenVPN config",
              "--file-filter=OpenVPN | *.ovpn *.conf", "--file-filter=All files | *"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var path = String(text || "").trim()
        if (path !== "") root.actionFinished("pick", true, path)
      }
    }
  }

  // ── Cadence ──────────────────────────────────────────────────────────────
  // Rare when idle, fast during a transition and while the panel is open.
  // Throughput only runs when something actually displays it.
  Timer {
    interval: root.busy ? 700 : (root.detailed ? 2000 : root.intervalSec * 1000)
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  Timer {
    interval: root.detailed ? 1000 : 2000
    running: root.iface !== "" && (root.detailed || root.showRate)
    repeat: true
    triggeredOnStart: true
    onTriggered: if (!statsProc.running) statsProc.running = true
  }

  Timer {
    interval: 1000
    running: root.detailed && root.since > 0
    repeat: true
    onTriggered: root.uptimeSeconds = Model.uptimeSeconds(root.since, Date.now())
  }

  Timer {
    interval: 5000
    running: root.detailed
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refreshProfiles()
  }

  Component.onCompleted: {
    helperProc.running = true
    refreshProfiles()
  }

  onDetailedChanged: if (detailed) { refreshDetails(); refreshProfiles(); helperProc.running = true }
}
