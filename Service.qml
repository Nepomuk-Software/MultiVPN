import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

// All state for the VPN widget. The panel only reads from here and calls
// actions, which keeps presentation free of process plumbing.
//
// Privilege model: reading needs no root at all. Writing goes through pkexec
// and the helper at /usr/local/bin/multivpn-admin, and the profile list
// comes from that helper's cache so merely opening the panel never raises an
// auth dialog. NetworkManager-owned WireGuard connections skip the helper
// entirely — nmcli lists them unprivileged and polkit governs the rest.
Item {
  id: root

  property var settings: ({})
  property bool detailed: false        // panel open → poll faster, fetch details
  property QtObject bar: null          // for the one action that needs a terminal

  readonly property string helperPath: "/usr/local/bin/multivpn-admin"
  readonly property string cachePath: "/var/lib/multivpn/profiles.json"

  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  readonly property string backendName: {
    var raw = String(setting("backend", "openvpn"))
    return Model.BACKENDS[raw] ? raw : "openvpn"
  }
  readonly property var caps: Model.backend(backendName)
  readonly property bool unified: backendName === "unified"

  // Pinning the widget to one backend is a filter over the same probe, not a
  // second way of asking. GlobalProtect has no per-connection name to match on.
  readonly property string filterBackend: unified ? "" : backendName
  readonly property string filterName:
    (unified || backendName === "globalprotect") ? "" : profile

  // Several VPNs can be up at once — split tunnels coexist without trouble.
  // The detail and throughput view follows one of them; this is which.
  property var activeConnections: []
  property string focusedKey: ""

  readonly property var focused: {
    if (activeConnections.length === 0) return null
    for (var i = 0; i < activeConnections.length; i++)
      if (connectionKey(activeConnections[i]) === focusedKey) return activeConnections[i]
    return activeConnections[0]
  }

  // Only full-tunnel configs collide, and only over the default route. Worth
  // pointing out when it happens; not worth preventing beforehand.
  readonly property int defaultRouteCount: {
    var n = 0
    for (var i = 0; i < activeConnections.length; i++)
      if (activeConnections[i].hasDefaultRoute) n++
    return n
  }

  function connectionKey(c) {
    return c ? c.backend + "/" + c.name : ""
  }
  property var portals: []

  // Which VPN tooling exists on this machine, so the panel can say so instead
  // of leaving the user guessing what "VPN" covers here.
  property var availability: ({})
  // Which connection the cached details belong to. Server and cipher come from
  // the OpenVPN journal and would otherwise survive a switch to another VPN
  // and be shown against it.
  property string detailIdentity: ""
  readonly property string availabilityLabel: Model.availabilityLabel(availability)
  readonly property bool hasFilePicker: availability.zenity === "1"

  // For OpenVPN and WireGuard this is a profile/interface name; for
  // GlobalProtect it is the portal server.
  readonly property string profile: {
    var raw = String(setting("profile", backendName === "openvpn" ? "work" : ""))
    return /^[A-Za-z0-9._:@\/-]*$/.test(raw) ? raw : ""
  }
  readonly property int intervalSec: Math.max(1, Number(setting("intervalSec", 5)))
  readonly property bool showRate: setting("showRate", false) === true

  // ── Connection state ─────────────────────────────────────────────────────
  // All of this describes the focused connection. Derived rather than stored:
  // four copies of the same truth was how a WireGuard tunnel ended up showing
  // OpenVPN's server.
  readonly property string activeBackend: focused ? focused.backend : ""
  readonly property string activeName: focused ? focused.name : ""
  readonly property string activeOrigin: focused ? focused.origin : ""
  readonly property string iface: focused ? focused.iface : ""
  readonly property string address: focused ? focused.address : ""
  readonly property string mtu: focused ? focused.mtu : ""
  readonly property string linkKind: focused ? (focused.kind || "") : ""
  readonly property var routes: focused ? focused.routes : []
  readonly property int since: focused ? focused.since : 0
  readonly property string unitState: activeConnections.length > 0 ? "active" : "inactive"

  // OpenVPN's in-kernel DCO driver ("ovpn") never increments the netdev's
  // receive counters — /proc/net/dev and `ip -s link` show the same zero. So
  // the download figure is not a measurement of nothing, it is missing, and
  // the panel has to say which. Gated on the counters too, so a kernel that
  // starts reporting makes this disappear on its own.
  readonly property bool rxUnavailable: linkKind === "ovpn" && rxBytes === 0 && txBytes > 0
  property string server: ""
  property string cipher: ""
  property string intent: ""           // "" | "up" | "down"
  property string actionStatus: ""
  property string lastError: ""
  property bool helperInstalled: false

  // The probe only lists what is up, so a failed attempt leaves no trace in it.
  // This keeps the label honest until something connects.
  property bool lastAttemptFailed: false
  property string lastAttemptName: ""

  readonly property bool connected: unitState === "active" && address !== ""
  readonly property bool failed: lastAttemptFailed && activeConnections.length === 0
  readonly property bool busy: intent !== "" || (unitState === "active" && address === "")
  readonly property string stateLabel:
    Model.stateLabel(failed ? "failed" : unitState, address, intent)

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
  property var nmProfiles: []
  property string profileStates: ""
  readonly property var profiles: {
    var base = Model.mergeProfiles(cachedProfiles, nmProfiles, profileStates, filterBackend)
    if (!unified) return base

    var out = base.concat(Model.portalProfiles(portals))
    // gpclient redacts host names in its log, so with several portals
    // configured there is no way to tell which one is up. Mark none rather
    // than guess — the header still reports that GlobalProtect is connected.
    if (activeBackend === "globalprotect" && portals.length === 1) {
      for (var i = 0; i < out.length; i++)
        if (out[i].backend === "globalprotect") out[i].state = "active"
    }
    return out
  }

  signal actionFinished(string command, bool ok, string message)

  // ── Actions ──────────────────────────────────────────────────────────────

  function refresh() { if (!statusProc.running) statusProc.running = true }

  // Server and cipher only exist in OpenVPN's journal, and only for the
  // connection currently in focus.
  function refreshDetails() {
    if (activeBackend !== "openvpn" || !activeName) return
    if (!detailProc.running) detailProc.running = true
  }

  function refreshProfiles() {
    // Cheap, and it is how the panel notices the installer just ran.
    if (!helperProc.running) helperProc.running = true
    if (!availabilityProc.running) availabilityProc.running = true
    if (!caps.canList) return
    if (!cacheProc.running) cacheProc.running = true
    if ((filterBackend === "" || filterBackend === "wireguard") && !nmListProc.running)
      nmListProc.running = true
    if (unified && !portalLoad.running) portalLoad.running = true
    if (!profileStateProc.running) profileStateProc.running = true
  }

  function toggle() {
    if (activeConnections.length > 0) { disconnectActive(); return }
    connect()
  }

  // The bar's right-click needs one obvious target when nothing is up. The
  // `profile` setting is that favourite.
  function favourite() {
    // GlobalProtect has no listable profiles, so the configured portal stands
    // in for one.
    if (backendName === "globalprotect")
      return profile ? { backend: "globalprotect", origin: "process",
                         name: profile, state: "inactive" } : null
    if (!profile) return null
    for (var i = 0; i < profiles.length; i++)
      if (profiles[i].name === profile) return profiles[i]
    return null
  }

  // Activating a row from the list. Connections are not mutually exclusive:
  // split-tunnel VPNs coexist, and only full-tunnel configs collide — over the
  // default route, which the panel reports rather than prevents.
  function activate(p) {
    if (!p || intent !== "") return
    if (p.state === "active") { disconnectProfile(p); return }
    focusedKey = p.backend + "/" + p.name
    connectProfile(p)
  }

  function connectProfile(p) {
    if (p.backend === "globalprotect") { launchGlobalProtect(p.name); return }
    intent = "up"
    actionStatus = ""
    lastError = ""
    lastAttemptName = p.name
    runAction(commandFor(p.backend, p.origin, p.name, "up"))
  }

  function disconnectProfile(p) {
    intent = "down"
    actionStatus = ""
    // Which row is mid-flight, so its switch can show it.
    lastAttemptName = p.name
    runAction(commandFor(p.backend, p.origin, p.name, "down"))
  }

  // Takes down the focused connection, not all of them.
  function disconnectActive() {
    if (!focused) return
    disconnectProfile(focused)
  }

  function connect() {
    var f = favourite()
    if (f) activate(f)
  }

  function disconnect() { disconnectActive() }

  function launchGlobalProtect(portal) {
    if (!bar) return
    var command = portal
      ? "omarchy-launch-floating-terminal-with-presentation sudo -E gpclient connect "
        + Model.shellQuote(portal)
      : "gpclient launch-gui"
    bar.run(command)
    actionFinished("launch", true, portal ? "opening terminal" : "opening GlobalProtect")
  }

  // One place that knows how each backend is actually switched.
  function commandFor(forBackend, useOrigin, name, direction) {
    if (forBackend === "globalprotect")
      return ["pkexec", "gpclient", "disconnect"]

    if (forBackend === "wireguard" && useOrigin === "nm")
      return ["nmcli", "connection", direction === "down" ? "down" : "up", "id", name]

    var unit = (forBackend === "wireguard" ? "wg-quick@" : "openvpn-client@") + name + ".service"
    return ["systemctl", direction === "down" ? "stop" : "start", unit]
  }

  function runAction(command) {
    unitAction.actionCommand = command
    unitAction.running = true
  }

  function setAutostart(name, useOrigin, on, forBackend) {
    var target = forBackend || backendName
    if (target === "globalprotect") return
    // NetworkManager keeps its own autoconnect flag; no helper involved.
    if (useOrigin === "nm") {
      nmAutostart.command = ["nmcli", "connection", "modify", name,
                             "connection.autoconnect", on ? "yes" : "no"]
      actionStatus = "Setting autostart…"
      nmAutostart.running = true
      return
    }
    admin(["autostart", target, name, on ? "on" : "off"], "autostart")
  }

  function importConfig(sourcePath, name, kind) {
    admin(["import", kind || backendName, sourcePath, name], "import")
  }

  // The other way in for WireGuard. Needs neither the root helper nor
  // wireguard-tools, which is why the panel offers it first.
  readonly property bool canImportToNm: availability.nmcli === "1"
  readonly property bool canImportToWgQuick: availability.wgquick === "1"

  function importToNetworkManager(sourcePath, name) {
    if (!canImportToNm) { lastError = "NetworkManager is not available"; return }
    nmImport.command = ["bash", "-lc", Model.nmImportScript(sourcePath, name)]
    actionStatus = "Importing into NetworkManager…"
    lastError = ""
    nmImport.running = true
  }

  // Which kind of config was picked, so the user never has to say.
  function detectConfigKind(path) {
    detectProc.sourcePath = path
    detectProc.running = true
  }

  // ── GlobalProtect portals ────────────────────────────────────────────────
  // gpclient has no system-wide portal registry, so the widget keeps a plain
  // list of host names of its own. Nothing here is privileged or secret.
  readonly property string portalsPath:
    Quickshell.env("HOME") + "/.local/state/multivpn/portals.json"

  function addPortal(name) {
    var clean = String(name || "").trim()
    if (!clean) return
    for (var i = 0; i < portals.length; i++)
      if (portals[i] === clean) return
    savePortals(portals.concat([clean]))
  }

  function removePortal(name) {
    savePortals(portals.filter(function(p) { return p !== name }))
  }

  function savePortals(list) {
    portals = list
    portalSave.command = ["bash", "-lc",
      "mkdir -p " + Model.shellQuote(portalsPath.replace(/\/[^\/]*$/, "")) +
      " && printf '%s' " + Model.shellQuote(JSON.stringify(list)) +
      " > " + Model.shellQuote(portalsPath)]
    portalSave.running = true
  }

  function removeProfile(name, useOrigin, forBackend) {
    if (useOrigin === "nm") {
      nmAutostart.command = ["nmcli", "connection", "delete", name]
      actionStatus = "Removing connection…"
      nmAutostart.running = true
      return
    }
    if (forBackend === "globalprotect") { removePortal(name); return }
    admin(["remove", forBackend || backendName, name], "remove")
  }

  function setCredentials(name, user, password) {
    if (!helperInstalled) { lastError = helperMissing; return }
    credentialsProc.secret = user + "\n" + password + "\n"
    credentialsProc.command = ["pkexec", helperPath, "credentials", "openvpn", name]
    actionStatus = "Setting credentials…"
    credentialsProc.running = true
  }

  function pickConfigFile() {
    if (!hasFilePicker) return
    if (!filePicker.running) filePicker.running = true
  }

  // The installer is deliberately NOT run through pkexec: it lives in a
  // directory the user can write, and pkexec-ing a user-writable script is a
  // textbook privilege escalation. A terminal asks for the password itself and
  // shows what the script does, which is what you want before granting root.
  function runSetup() {
    if (!bar) return
    var path = Qt.resolvedUrl("system/install.sh").toString().replace(/^file:\/\//, "")
    bar.run("omarchy-launch-floating-terminal-with-presentation sudo bash " + Model.shellQuote(path))
    actionFinished("setup", true, "opening terminal")
  }

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
    var previousIface = iface
    var all = Model.parseConnections(raw)

    activeConnections = filterBackend === "" ? all : all.filter(function(c) {
      if (c.backend !== filterBackend) return false
      return filterName === "" || c.name === filterName
    })

    if (activeConnections.length > 0) lastAttemptFailed = false
    uptimeSeconds = Model.uptimeSeconds(since, Date.now())

    // Details are per connection. Drop them the moment the identity changes,
    // so a WireGuard tunnel never inherits OpenVPN's server and cipher.
    var identity = activeBackend + "/" + activeName
    if (identity !== detailIdentity) {
      detailIdentity = identity
      server = ""
      cipher = ""
      refreshDetails()
    }

    // A different interface is a different session, so its counters must not
    // continue the previous curve.
    if (!iface || iface !== previousIface) resetStats()
  }

  function focusConnection(c) {
    focusedKey = connectionKey(c)
    refresh()
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
    command: ["bash", "-lc", Model.statusScript()]
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.applyStatus(text) }
  }

  Process {
    id: detailProc
    command: ["bash", "-lc", Model.detailScript("openvpn", root.activeName)]
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
    // head(1) rather than cat: the cache is a file this widget does not write,
    // and a StdioCollector buffers whatever it is handed.
    command: ["bash", "-lc", "head -c " + Model.MAX_OUTPUT + " " + Model.shellQuote(root.cachePath) + " 2>/dev/null"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.cachedProfiles = Model.parseProfiles(text)
    }
  }

  Process {
    id: nmListProc
    command: ["bash", "-lc", Model.nmWireguardListScript()]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.nmProfiles = Model.parseNmProfiles(text)
    }
  }

  Process {
    id: profileStateProc
    command: ["bash", "-lc", Model.profileStateScript(
      root.cachedProfiles.concat(root.nmProfiles).filter(function(p) {
        return root.filterBackend === "" || (p.backend || "openvpn") === root.filterBackend
      }))]
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.profileStates = text }
  }

  Process {
    id: nmImport
    stderr: StdioCollector { waitForEnd: true }
    onExited: function(code) {
      root.actionStatus = ""
      if (code === 0) {
        root.lastError = ""
        root.refreshProfiles()
        root.refresh()
        root.actionFinished("import", true, "imported into NetworkManager")
      } else {
        root.lastError = Model.clamp(stderr.text, Model.MAX_FIELD).trim() || "NetworkManager import failed"
        root.actionFinished("import", false, root.lastError)
      }
    }
  }

  Process {
    id: availabilityProc
    command: ["bash", "-lc", Model.availabilityScript()]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.availability = Model.parseKeyValues(text)
    }
  }

  Process {
    id: detectProc
    property string sourcePath: ""
    command: ["bash", "-lc", Model.detectKindScript(sourcePath)]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.actionFinished("detect", true, Model.clamp(text, Model.MAX_FIELD).trim())
    }
  }

  Process {
    id: portalLoad
    command: ["bash", "-lc", "head -c " + Model.MAX_OUTPUT + " " + Model.shellQuote(root.portalsPath) + " 2>/dev/null"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          // A whole JSON document, not one field: MAX_FIELD would truncate a
          // valid portal list into a parse error.
          var parsed = JSON.parse(Model.clamp(text).trim() || "[]")
          root.portals = Array.isArray(parsed) ? parsed : []
        } catch (e) {
          root.portals = []
        }
      }
    }
  }

  Process {
    id: portalSave
    onExited: function(code) { if (code !== 0) root.lastError = "Could not save portal list" }
  }

  Process {
    id: helperProc
    command: ["test", "-x", root.helperPath]
    onExited: function(code) { root.helperInstalled = code === 0 }
  }

  // openvpn-client@ and wg-quick@ are both Type=notify/oneshot, so systemctl
  // blocks until the tunnel reports or fails — the exit code already is the
  // result. `nmcli connection up` behaves the same way.
  Process {
    id: unitAction
    property var actionCommand: []
    command: actionCommand
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
        if (wasUp) root.lastAttemptFailed = true
        root.actionFinished("unit", false, wasUp ? "connection failed" : "disconnect failed")
        if (wasUp && root.activeBackend !== "wireguard") reasonProc.running = true
        else root.lastError = wasUp ? "Connection failed" : "Disconnect failed"
      }
    }
  }

  Process {
    id: nmAutostart
    stderr: StdioCollector { waitForEnd: true }
    onExited: function(code) {
      root.actionStatus = ""
      if (code === 0) { root.lastError = ""; root.refreshProfiles() }
      else root.lastError = Model.clamp(stderr.text, Model.MAX_FIELD).trim() || "nmcli failed"
    }
  }

  // When bringing an OpenVPN tunnel up fails, the reason is in the journal.
  Process {
    id: reasonProc
    command: ["bash", "-lc",
      "journalctl -u " + Model.shellQuote("openvpn-client@" + root.lastAttemptName + ".service")
      + " -n 40 --no-pager -o cat 2>/dev/null | "
      + "grep -oE 'AUTH_FAILED|TLS Error|Connection refused|Cannot open' | tail -1 | head -c 64"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var why = Model.clamp(text, Model.MAX_FIELD).trim()
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
        root.actionFinished(label, true, Model.clamp(stdout.text, Model.MAX_FIELD).trim())
      } else if (code === 126 || code === 127) {
        // pkexec: dismissed or not authorised.
        root.actionFinished(label, false, "cancelled")
      } else {
        root.lastError = Model.clamp(stderr.text, Model.MAX_FIELD).trim() || "Action failed"
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
        root.lastError = Model.clamp(stderr.text, Model.MAX_FIELD).trim() || "Could not set credentials"
        root.actionFinished("credentials", false, root.lastError)
      }
    }
  }

  // zenity ships with Omarchy and is the only file dialog involved.
  Process {
    id: filePicker
    command: ["zenity", "--file-selection", "--title=Select a VPN config",
              "--file-filter=VPN configs | *.ovpn *.conf", "--file-filter=All files | *"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        // A path, not a label: MAX_FIELD would quietly point the import at a
        // different file rather than at the one that was picked.
        var path = Model.clamp(text, Model.MAX_PATH).trim()
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
