import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Bar icon plus popup for one openvpn-client@<profile>.service instance.
//
//   left = panel · right = tunnel on/off · middle = refresh
//
// Everything that reads works without root. Profile management goes through
// pkexec and the helper in system/. Without that helper the panel stays fully
// usable; only the profile section says what is missing.
Panel {
  id: root
  moduleName: "io.github.nepomuk-software.multivpn"
  ipcTarget: "io.github.nepomuk-software.multivpn"
  manageIpc: false

  // Lets peer instances on other monitors reach this one's state.
  readonly property alias service: vpn

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  readonly property bool vertical: bar ? bar.vertical : false
  readonly property bool showRate: setting("showRate", false) === true && !vertical
  readonly property bool highlightWhenConnected: setting("highlightWhenConnected", false) === true

  // Form state. Import and credentials share the space at the bottom of the
  // panel; only one is open at a time so the height stays sane.
  property string importPath: ""
  property string importName: ""
  property string credentialsProfile: ""
  property string removeTarget: ""
  property string removeOrigin: ""
  property string removeBackend: ""
  property string importKind: ""
  property bool importOpen: false
  // Where a WireGuard config should land. NetworkManager needs no root helper
  // and no wireguard-tools, so it wins when both are possible.
  property string importTarget: ""
  property bool portalFormOpen: false
  property bool setupOpen: false
  property int profileIndex: 0
  property bool cursorActive: false

  readonly property string barTooltip: {
    var base = root.caps.label + (vpn.profile ? " " + vpn.profile : "") + " " + vpn.stateLabel
    if (vpn.connected) return base + " · " + vpn.address
    if (vpn.failed) return base + " · right-click to retry"
    return base + " · right-click to connect"
  }

  // Which backend the panel is actually describing right now — always the
  // focused connection's, in every mode.
  readonly property string effectiveBackend: vpn.activeBackend

  // In unified mode the interesting profile is the one that is up, not the one
  // named in the settings — that setting is only the right-click favourite.
  readonly property var currentProfile: {
    var wantName = vpn.unified ? vpn.activeName : vpn.profile
    var wantBackend = root.effectiveBackend
    if (!wantName) return null
    for (var i = 0; i < vpn.profiles.length; i++) {
      var p = vpn.profiles[i]
      if (p.name === wantName && (!wantBackend || p.backend === wantBackend)) return p
    }
    return null
  }

  // A bar surface exists per monitor, and the layout may hold one instance per
  // VPN profile. IPC only ever routes to one handler, so find the instance the
  // caller meant rather than acting on whichever registered first.
  function instanceFor(profileName) {
    var items = bar && typeof bar.moduleWidgets === "function"
      ? bar.moduleWidgets(moduleName) : [root]
    for (var i = 0; i < items.length; i++) {
      var w = items[i]
      if (w && w.service && (!profileName || w.service.profile === profileName)) return w
    }
    return null
  }

  function handlePress(mouseButton) {
    if (mouseButton === Qt.RightButton) vpn.toggle()
    else if (mouseButton === Qt.MiddleButton) { vpn.refresh(); vpn.refreshProfiles() }
    else root.toggle()
  }

  function closeForms() {
    importPath = ""
    importName = ""
    credentialsProfile = ""
    removeTarget = ""
    removeOrigin = ""
    removeBackend = ""
    importKind = ""
    importTarget = ""
    importOpen = false
    portalFormOpen = false
    setupOpen = false
  }

  function moveCursor(dy) {
    cursorActive = true
    if (vpn.profiles.length === 0) return
    profileIndex = Math.max(0, Math.min(vpn.profiles.length - 1, profileIndex + dy))
  }

  function activateCursor() {
    if (!cursorActive || vpn.profiles.length === 0) return
    var p = vpn.profiles[profileIndex]
    if (p) p.state === "active" ? vpn.focusConnection(p) : vpn.activate(p)
  }

  Service {
    id: vpn
    settings: root.settings
    detailed: root.opened
    bar: root.bar
  }

  // What this backend can actually do. Drives which controls exist at all —
  // GlobalProtect has no profile list, WireGuard has no password to type.
  readonly property var caps: vpn.caps

  Connections {
    target: vpn
    function onActionFinished(command, ok, message) {
      if (command === "pick" && ok) {
        // Suggested profile name: file name without extension, sanitised.
        var file = message.split("/").pop()
        root.importPath = message
        root.importName = file.replace(/\.(ovpn|conf)$/i, "")
                              .replace(/[^A-Za-z0-9._-]/g, "-")
                              .substring(0, 32)
        root.importKind = ""
        root.importOpen = true
        root.credentialsProfile = ""
        vpn.detectConfigKind(message)
      } else if (command === "detect" && ok) {
        root.importKind = message
        root.importTarget = message !== "wireguard" ? ""
                            : vpn.canImportToNm ? "nm"
                            : vpn.canImportToWgQuick ? "wg-quick" : ""
      } else if (command === "import" && ok) {
        root.closeForms()
      } else if (command === "credentials" && ok) {
        root.credentialsProfile = ""
      } else if (command === "remove" && ok) {
        root.removeTarget = ""
      }
    }
  }

  IpcHandler {
    target: root.ipcTarget

    // `toggle` belongs to the popup, as it does on the built-in Omarchy panels.
    // The connection gets its own routes so keybindings stay unambiguous.
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }

    function toggleVpn(): void { vpn.toggle() }
    function connect(): void { vpn.connect() }
    function disconnect(): void { vpn.disconnect() }

    // Same three, addressed at a specific profile — for layouts that carry
    // more than one instance of this widget.
    function toggleVpnFor(profile: string): void {
      var w = root.instanceFor(profile); if (w) w.service.toggle()
    }
    function connectFor(profile: string): void {
      var w = root.instanceFor(profile); if (w) w.service.connect()
    }
    function disconnectFor(profile: string): void {
      var w = root.instanceFor(profile); if (w) w.service.disconnect()
    }

    function refresh(): string { vpn.refresh(); vpn.refreshProfiles(); return "ok" }
    function status(): string { return root.statusLine(vpn) }
    function statusFor(profile: string): string {
      var w = root.instanceFor(profile)
      return w ? root.statusLine(w.service) : "unknown"
    }
  }

  function statusLine(s) {
    if (s.connected)
      return "connected " + s.address + " rx=" + Math.round(s.rxBytes) + " tx=" + Math.round(s.txBytes)
    return s.busy ? "connecting" : s.unitState
  }

  // ── Bar face ───────────────────────────────────────────────────────────────
  // Icon alone, or icon plus throughput when showRate is set. Two components,
  // because the icon variant is optically centred and the label variant is not.
  implicitWidth: face.implicitWidth
  implicitHeight: face.implicitHeight

  Loader {
    id: face
    anchors.fill: parent
    sourceComponent: root.showRate && vpn.connected ? labelFace : iconFace
  }

  Component {
    id: iconFace
    BarIconButton {
      bar: root.bar
      text: "󰖂"
      active: vpn.connected && root.highlightWhenConnected
      dimmed: !vpn.connected && !vpn.busy
      tooltipText: root.barTooltip
      onPressed: function(mouseButton) { root.handlePress(mouseButton) }
    }
  }

  Component {
    id: labelFace
    WidgetButton {
      bar: root.bar
      text: "󰖂  " + (vpn.rxUnavailable ? "" : "↓" + Model.rate(vpn.rxRate) + " ")
            + "↑" + Model.rate(vpn.txRate)
      active: vpn.connected && root.highlightWhenConnected
      tooltipText: root.barTooltip
      fontSize: Style.font.caption
      onPressed: function(mouseButton) { root.handlePress(mouseButton) }
    }
  }

  // Acknowledges the click straight away instead of waiting for the next poll.
  SequentialAnimation {
    running: vpn.busy
    loops: Animation.Infinite
    NumberAnimation { target: face; property: "opacity"; to: 0.3; duration: 550; easing.type: Easing.InOutQuad }
    NumberAnimation { target: face; property: "opacity"; to: 1.0; duration: 550; easing.type: Easing.InOutQuad }
    onRunningChanged: if (!running) face.opacity = 1
  }

  // ── Popup ──────────────────────────────────────────────────────────────────
  KeyboardPanel {
    id: panel
    anchorItem: face
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(400))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(620))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function(dx, dy) {
        if (!root.cursorActive) { root.cursorActive = true; return }
        if (dy !== 0) root.moveCursor(dy)
      }
      onActivateRequested: root.activateCursor()
      onCloseRequested: {
        // Escape backs out of an open form first, then out of the panel.
        if (root.importPath !== "" || root.credentialsProfile !== "" || root.removeTarget !== "")
          root.closeForms()
        else
          root.close()
      }
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        var key = String(t).toLowerCase()
        if (key === "v") vpn.toggle()
        else if (key === "r") { vpn.refresh(); vpn.refreshDetails(); vpn.refreshProfiles() }
        else if (key === "n" && root.caps.canImport) {
          root.closeForms()
          if (vpn.helperInstalled) { root.importOpen = true; vpn.pickConfigFile() }
          else root.setupOpen = true
        }
      }

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: column
          width: panelFlick.width
          spacing: Style.space(12)

          // ── Header ──────────────────────────────────────────────────────
          Item {
            width: parent.width
            implicitHeight: hero.implicitHeight

            PanelHero {
              id: hero
              width: parent.width
              title: vpn.unified && vpn.activeBackend
                     ? Model.backend(vpn.activeBackend).label
                     : root.caps.label
              meta: {
                if (!vpn.unified) return (vpn.profile ? vpn.profile + " · " : "") + vpn.stateLabel
                var n = vpn.activeConnections.length
                if (n === 0) return "nothing connected"
                var label = (vpn.activeName ? vpn.activeName + " · " : "") + vpn.stateLabel
                return n > 1 ? label + "  ·  " + n + " connected" : label
              }
              // The hero's detail slot is a fixed-width pill for something
              // short; the availability line gets its own row below.
              detail: vpn.connected ? "up " + Model.duration(vpn.uptimeSeconds) : ""
              foreground: root.foreground
              fontFamily: root.fontFamily
              iconComponent: Component {
                Text {
                  text: "󰖂"
                  color: vpn.connected ? root.foreground : root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.display
                }
              }
              // No switch here. It looked global while acting on one
              // connection, and the list below already owns on/off per VPN.
            }
          }

          // Which VPN tooling this machine actually has. Without it the panel
          // says "VPN" and leaves you guessing what that covers here.
          Text {
            visible: vpn.unified && !vpn.connected && !vpn.busy
            width: parent.width
            text: vpn.availabilityLabel
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }

          Text {
            visible: vpn.actionStatus !== "" || vpn.lastError !== ""
            width: parent.width
            text: vpn.actionStatus !== "" ? vpn.actionStatus : vpn.lastError
            color: vpn.actionStatus !== "" ? root.dim : root.urgent
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          // Only full-tunnel configs actually collide, and only here.
          Text {
            visible: vpn.defaultRouteCount > 1
            width: parent.width
            text: "Two connections claim the default route. Whichever the kernel prefers wins; "
                  + "the other's traffic will not take its tunnel."
            color: root.urgent
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          // ── Connection ──────────────────────────────────────────────────
          Column {
            visible: vpn.connected || vpn.busy
            width: parent.width
            spacing: Style.spacing.labelGap

            // Names the connection it describes, since the list below is what
            // chooses it.
            PanelSectionHeader {
              text: vpn.activeConnections.length > 1 && vpn.activeName
                    ? "CONNECTION · " + vpn.activeName.toUpperCase()
                    : "CONNECTION"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            InfoPair {
              label: "Server"
              value: {
                if (root.currentProfile && root.currentProfile.remote)
                  return root.currentProfile.remote
                         + (root.currentProfile.port ? ":" + root.currentProfile.port : "")
                if (root.effectiveBackend === "openvpn" && vpn.server) return vpn.server
                if (root.effectiveBackend === "globalprotect") return vpn.profile || "—"
                return "—"
              }
            }
            // Protocol and cipher are one fact about the transport; two rows
            // for eleven characters was waste.
            InfoPair {
              label: "Transport"
              value: {
                var proto = root.currentProfile && root.currentProfile.proto
                            ? root.currentProfile.proto.toUpperCase()
                            : (root.effectiveBackend ? Model.backend(root.effectiveBackend).label : "")
                return vpn.cipher ? proto + "  ·  " + vpn.cipher : (proto || "—")
              }
            }
            // Wrapped like the route list, not elided into uselessness — and
            // skipped entirely when the kernel routes already say the same.
            Column {
              readonly property var entries: {
                if (root.effectiveBackend !== "wireguard" || !root.currentProfile) return []
                var raw = String(root.currentProfile.allowedIps || "")
                if (!raw) return []
                var list = raw.split(/[;,]/).map(function(x) { return x.trim() })
                                            .filter(function(x) { return x !== "" })
                if (list.length === vpn.routes.length
                    && list.slice().sort().join() === vpn.routes.slice().sort().join())
                  return []
                return list
              }

              visible: entries.length > 0
              width: parent.width
              spacing: Style.spacing.xxs

              Text {
                text: "Allowed IPs"
                color: root.foreground
                opacity: 0.6
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
              }
              Text {
                width: parent.width
                text: parent.entries.join("  ·  ")
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                wrapMode: Text.WordWrap
              }
            }
            InfoPair { label: "Tunnel IP"; value: vpn.address || "—" }
            InfoPair {
              label: "Interface"
              value: vpn.iface ? vpn.iface + (vpn.mtu ? " · MTU " + vpn.mtu : "") : "—"
            }

            Column {
              visible: vpn.routes.length > 0
              width: parent.width
              spacing: Style.spacing.xxs

              Text {
                text: "Routes"
                color: root.foreground
                opacity: 0.6
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
              }
              Text {
                width: parent.width
                text: vpn.routes.join("  ·  ")
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                wrapMode: Text.WordWrap
              }
            }
          }

          // ── Throughput ──────────────────────────────────────────────────
          Column {
            visible: vpn.connected
            width: parent.width
            spacing: Style.space(6)

            PanelSectionHeader {
              text: "THROUGHPUT"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Sparkline {
              width: parent.width
              points: vpn.history
              peak: vpn.peakRate
              showRx: !vpn.rxUnavailable
              rxColor: root.foreground
              txColor: root.foreground
            }

            Text {
              visible: vpn.rxUnavailable
              width: parent.width
              text: "DCO does not report received bytes to the kernel counters — "
                    + "only the upload figure is real."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }

            Row {
              width: parent.width
              spacing: Style.space(16)

              Text {
                text: vpn.rxUnavailable ? "↓ n/a" : "↓ " + Model.rate(vpn.rxRate) + "B/s"
                color: root.foreground
                opacity: vpn.rxUnavailable ? 0.5 : 1
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
              }
              Text {
                text: "↑ " + Model.rate(vpn.txRate) + "B/s"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
              }
              Item { width: Math.max(0, parent.width - Style.space(230)); height: 1 }
              Text {
                text: (vpn.rxUnavailable ? "—" : Model.bytes(vpn.rxBytes))
                      + " ↓  " + Model.bytes(vpn.txBytes) + " ↑"
                color: root.foreground
                opacity: 0.6
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
              }
            }
          }

          PanelSeparator { foreground: root.foreground }

          // ── Profiles ────────────────────────────────────────────────────
          Column {
            width: parent.width
            spacing: Style.space(6)

            PanelSectionHeader {
              text: root.caps.profileLabel.toUpperCase() + "S"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            // gpclient keeps its portals in the GUI's own config and logs in
            // over SSO, so there is nothing here to enumerate or drive.
            Text {
              visible: !root.caps.canList && !vpn.unified
              width: parent.width
              text: vpn.profile
                    ? "Portal " + vpn.profile + ". Connecting opens a terminal for the SSO login; "
                      + "the widget takes it from there."
                    : "No portal configured. Connecting opens the GlobalProtect GUI. Set one with "
                      + "`omarchy bar set io.github.nepomuk-software.multivpn profile <portal>`."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap
            }

            Column {
              visible: root.caps.canList && !vpn.helperInstalled
              width: parent.width
              spacing: Style.space(6)

              Text {
                width: parent.width
                text: "OpenVPN and wg-quick configs live in root-owned directories, so listing "
                      + "and importing them needs a one-time setup. Everything else already works."
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                wrapMode: Text.WordWrap
              }
              Button {
                text: "Set up profile management"
                iconText: "󰒓"
                bordered: true
                foreground: root.foreground
                fontFamily: root.fontFamily
                onClicked: root.setupOpen = true
              }
            }

            Text {
              visible: root.caps.canList && vpn.helperInstalled && vpn.profiles.length === 0
              width: parent.width
              text: vpn.unified
                    ? "Nothing found. Add an OpenVPN or WireGuard config below, or a GlobalProtect portal."
                    : vpn.backendName === "wireguard"
                      ? "No interfaces in /etc/wireguard and none in NetworkManager."
                      : "No profiles in /etc/openvpn/client."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }

            Repeater {
              model: root.caps.canList ? vpn.profiles : []

              ProfileRow {
                width: column.width
                hasCursor: root.cursorActive && root.profileIndex === index
                // Click the row to use it: off turns it on, on shows its
                // details. Turning one off is its own switch, always visible.
                onActivated: profile.state === "active" ? vpn.focusConnection(profile)
                                                        : vpn.activate(profile)
                onAutostartToggled: vpn.setAutostart(profile.name, profile.origin,
                                                     !profile.autostart, profile.backend)
                onCredentialsRequested: { root.closeForms(); root.credentialsProfile = profile.name }
                onRemoveRequested: {
                  root.closeForms()
                  root.removeTarget = profile.name
                  root.removeOrigin = profile.origin
                  root.removeBackend = profile.backend
                }
                onHoveredChanged: if (hovered) { root.cursorActive = true; root.profileIndex = index }
              }
            }
          }

          // ── Actions ─────────────────────────────────────────────────────
          Row {
            width: parent.width
            spacing: Style.spacing.controlGap

            // GlobalProtect cannot be driven headlessly, so this hands off to
            // a terminal or the vendor GUI rather than pretending otherwise.
            Button {
              visible: root.caps.connectNeedsTerminal && !vpn.connected
              text: vpn.profile ? "Connect in terminal" : "Open GlobalProtect"
              iconText: "󰖂"
              bordered: true
              foreground: root.foreground
              fontFamily: root.fontFamily
              onClicked: vpn.connect()
            }
            // Always offered. Without the helper it explains what is missing
            // rather than being silently absent, which read as "not supported".
            Button {
              visible: root.caps.canImport
              text: "Add config"
              iconText: "󰐕"
              bordered: true
              foreground: root.foreground
              fontFamily: root.fontFamily
              onClicked: {
                root.closeForms()
                if (!vpn.helperInstalled) { root.setupOpen = true; return }
                root.importOpen = true
                vpn.pickConfigFile()
              }
            }
            // GlobalProtect portals are not files, so they get their own entry.
            Button {
              visible: root.caps.canPortals === true
              text: "Add portal"
              iconText: "󰇧"
              bordered: true
              foreground: root.foreground
              fontFamily: root.fontFamily
              onClicked: { root.closeForms(); root.portalFormOpen = true }
            }
          }

          // ── Import form ─────────────────────────────────────────────────
          // The path is editable on purpose: the file dialog is a convenience,
          // not the only way in. Without zenity, or when it is cancelled, you
          // can still paste a path.
          Column {
            visible: root.importOpen
            width: parent.width
            spacing: Style.space(6)

            PanelSeparator { foreground: root.foreground }
            PanelSectionHeader {
              text: "ADD OPENVPN OR WIREGUARD CONFIG"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Row {
              width: parent.width
              spacing: Style.spacing.controlGap

              TextField {
                id: pathField
                width: parent.width - browseButton.width - Style.spacing.controlGap
                text: root.importPath
                placeholderText: "path to an .ovpn or .conf file"
                foreground: root.foreground
                onTextChanged: {
                  root.importPath = text
                  root.importKind = ""
                  detectDelay.restart()
                }
              }
              Button {
                id: browseButton
                text: "Browse"
                bordered: true
                enabled: vpn.hasFilePicker
                tooltipText: vpn.hasFilePicker ? "" : "zenity is not installed"
                foreground: root.foreground
                fontFamily: root.fontFamily
                onClicked: vpn.pickConfigFile()
              }
            }

            // Typing a path should not spawn a probe per keystroke.
            Timer {
              id: detectDelay
              interval: 400
              onTriggered: if (root.importPath !== "") vpn.detectConfigKind(root.importPath)
            }

            Text {
              width: parent.width
              text: root.importPath === "" ? "Pick or paste a file to continue."
                    : root.importKind === "unknown"
                      ? "Not recognised as an OpenVPN or WireGuard config."
                      : root.importKind
                        ? "Detected: " + Model.backend(root.importKind).label
                        : "Checking file…"
              color: root.importKind === "unknown" ? root.urgent : root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }

            // WireGuard can go two ways on the same machine, and they differ
            // in what they cost the user, so the choice is explicit.
            Column {
              visible: root.importKind === "wireguard"
              width: parent.width
              spacing: Style.space(4)

              Text {
                text: "Install into"
                color: root.foreground
                opacity: 0.6
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
              Row {
                spacing: Style.spacing.controlGap
                Button {
                  text: "NetworkManager"
                  bordered: true
                  enabled: vpn.canImportToNm
                  selected: root.importTarget === "nm"
                  tooltipText: "No root helper needed"
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  onClicked: root.importTarget = "nm"
                }
                Button {
                  text: "wg-quick"
                  bordered: true
                  enabled: vpn.canImportToWgQuick
                  selected: root.importTarget === "wg-quick"
                  tooltipText: vpn.canImportToWgQuick
                               ? "Installs into /etc/wireguard"
                               : "wireguard-tools is not installed"
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  onClicked: root.importTarget = "wg-quick"
                }
              }
              Text {
                visible: !vpn.canImportToWgQuick
                width: parent.width
                text: "wg-quick needs the wireguard-tools package; without it there is no "
                      + "wg-quick@ unit to start."
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                wrapMode: Text.WordWrap
              }
            }

            TextField {
              width: parent.width
              text: root.importName
              placeholderText: "profile name"
              foreground: root.foreground
              onTextChanged: root.importName = text
              onAccepted: importButton.clicked()
            }
            Row {
              spacing: Style.spacing.controlGap
              Button {
                id: importButton
                text: "Import"
                bordered: true
                enabled: /^[A-Za-z0-9][A-Za-z0-9._-]*$/.test(root.importName)
                         && root.importKind !== "" && root.importKind !== "unknown"
                         && (root.importKind !== "wireguard" || root.importTarget !== "")
                         && (root.importKind === "wireguard" || vpn.helperInstalled)
                foreground: root.foreground
                fontFamily: root.fontFamily
                onClicked: {
                  if (root.importKind === "wireguard" && root.importTarget === "nm")
                    vpn.importToNetworkManager(root.importPath, root.importName)
                  else
                    vpn.importConfig(root.importPath, root.importName, root.importKind)
                }
              }
              Button {
                text: "Cancel"
                bordered: true
                foreground: root.dim
                fontFamily: root.fontFamily
                onClicked: root.closeForms()
              }
            }
          }

          // ── Credentials form ────────────────────────────────────────────
          Column {
            visible: root.credentialsProfile !== "" && root.caps.canCredentials
            width: parent.width
            spacing: Style.space(6)

            PanelSeparator { foreground: root.foreground }
            PanelSectionHeader {
              text: "CREDENTIALS · " + root.credentialsProfile.toUpperCase()
              foreground: root.foreground
              fontFamily: root.fontFamily
            }
            TextField {
              id: userField
              width: parent.width
              placeholderText: "Username"
              foreground: root.foreground
            }
            TextField {
              id: passField
              width: parent.width
              placeholderText: "Password"
              password: true
              foreground: root.foreground
              onAccepted: saveCredentials.clicked()
            }
            Row {
              spacing: Style.spacing.controlGap
              Button {
                id: saveCredentials
                text: "Save"
                bordered: true
                enabled: userField.text !== "" && passField.text !== ""
                foreground: root.foreground
                fontFamily: root.fontFamily
                onClicked: {
                  vpn.setCredentials(root.credentialsProfile, userField.text, passField.text)
                  userField.text = ""
                  passField.text = ""
                }
              }
              Button {
                text: "Cancel"
                bordered: true
                foreground: root.dim
                fontFamily: root.fontFamily
                onClicked: { userField.text = ""; passField.text = ""; root.closeForms() }
              }
            }
          }

          // ── Setup form ──────────────────────────────────────────────────
          Column {
            visible: root.setupOpen
            width: parent.width
            spacing: Style.space(6)

            PanelSeparator { foreground: root.foreground }
            PanelSectionHeader {
              text: "SET UP PROFILE MANAGEMENT"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }
            Text {
              width: parent.width
              text: "Opens a terminal and runs system/install.sh with sudo. It installs a root "
                    + "helper, a polkit action and two systemd units so the panel can list and "
                    + "import root-owned configs. Undo with the same script and --uninstall."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }
            Text {
              width: parent.width
              text: "It runs in a terminal, not through a password dialog, so you can read the "
                    + "script before granting it root."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }
            Row {
              spacing: Style.spacing.controlGap
              Button {
                text: "Open terminal"
                iconText: "󰆍"
                bordered: true
                foreground: root.foreground
                fontFamily: root.fontFamily
                onClicked: { vpn.runSetup(); root.setupOpen = false }
              }
              Button {
                text: "Cancel"
                bordered: true
                foreground: root.dim
                fontFamily: root.fontFamily
                onClicked: root.closeForms()
              }
            }
          }

          // ── Portal form ─────────────────────────────────────────────────
          Column {
            visible: root.portalFormOpen
            width: parent.width
            spacing: Style.space(6)

            PanelSeparator { foreground: root.foreground }
            PanelSectionHeader {
              text: "ADD GLOBALPROTECT PORTAL"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }
            Text {
              width: parent.width
              text: "The portal host, e.g. vpn.example.com. Connecting opens a terminal "
                    + "for the SSO login."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }
            TextField {
              id: portalField
              width: parent.width
              placeholderText: "portal host"
              foreground: root.foreground
              onAccepted: savePortal.clicked()
            }
            Row {
              spacing: Style.spacing.controlGap
              Button {
                id: savePortal
                text: "Add"
                bordered: true
                enabled: portalField.text.trim() !== ""
                foreground: root.foreground
                fontFamily: root.fontFamily
                onClicked: {
                  vpn.addPortal(portalField.text)
                  portalField.text = ""
                  root.portalFormOpen = false
                }
              }
              Button {
                text: "Cancel"
                bordered: true
                foreground: root.dim
                fontFamily: root.fontFamily
                onClicked: { portalField.text = ""; root.closeForms() }
              }
            }
          }

          // ── Remove confirmation ─────────────────────────────────────────
          Column {
            visible: root.removeTarget !== ""
            width: parent.width
            spacing: Style.space(6)

            PanelSeparator { foreground: root.foreground }
            Text {
              width: parent.width
              text: root.removeBackend === "globalprotect"
                    ? "Remove portal “" + root.removeTarget + "” from the list?"
                    : "Remove profile “" + root.removeTarget + "” and its stored credentials?"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap
            }
            Row {
              spacing: Style.spacing.controlGap
              Button {
                text: "Remove"
                bordered: true
                foreground: root.urgent
                fontFamily: root.fontFamily
                onClicked: vpn.removeProfile(root.removeTarget, root.removeOrigin, root.removeBackend)
              }
              Button {
                text: "Cancel"
                bordered: true
                foreground: root.dim
                fontFamily: root.fontFamily
                onClicked: root.closeForms()
              }
            }
          }
        }
      }
    }
  }

  // ── Building blocks ────────────────────────────────────────────────────────

  component InfoPair: Row {
    property string label: ""
    property string value: ""

    width: parent.width
    spacing: Style.space(8)

    Text {
      id: pairLabel
      text: parent.label
      color: root.foreground
      opacity: 0.6
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
    }
    Item {
      width: Math.max(0, parent.width - pairLabel.implicitWidth - pairValue.implicitWidth - parent.spacing * 2)
      height: 1
    }
    Text {
      id: pairValue
      text: parent.value
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      elide: Text.ElideMiddle
    }
  }

  // One profile row. Positioners refuse anchored children, so this follows the
  // rest of the shell: an Item with anchors rather than a Row.
  component ProfileRow: Rectangle {
    id: row

    // Assigned by the Repeater.
    required property var modelData
    required property int index

    readonly property var profile: modelData
    // In unified mode each row can come from a different backend, so the
    // controls are decided here rather than for the widget as a whole.
    readonly property var rowCaps: Model.capsFor(profile ? profile.backend : "")
    property bool hasCursor: false
    readonly property alias hovered: rowMouse.containsMouse
    readonly property bool isCurrent: profile && profile.name === vpn.profile
    readonly property bool isActive: profile && profile.state === "active"
    readonly property bool isFocused: isActive && vpn.activeConnections.length > 1
                                      && vpn.connectionKey(profile) === vpn.connectionKey(vpn.focused)

    signal activated()
    signal autostartToggled()
    signal credentialsRequested()
    signal removeRequested()

    implicitHeight: Style.spacing.popupRowHeight + Style.space(8)
    radius: Style.cornerRadius
    color: hasCursor ? Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.07) : "transparent"

    MouseArea {
      id: rowMouse
      anchors.fill: parent
      hoverEnabled: true
      onClicked: row.activated()
    }

    // Marks the row the detail block is describing.
    Rectangle {
      visible: row.isFocused
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      width: Math.max(2, Style.space(2))
      height: parent.height - Style.space(8)
      radius: width / 2
      color: root.foreground
    }

    // Placeholder that keeps the label column clear of the focus bar.
    Item {
      id: dot
      anchors.left: parent.left
      anchors.leftMargin: Style.space(4)
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(4)
      height: width
    }

    // The switch is this row's on/off and its state display in one. Declared
    // after the MouseArea so it swallows the row click.
    ToggleSwitch {
      id: rowSwitch
      anchors.right: parent.right
      anchors.rightMargin: Style.space(4)
      anchors.verticalCenter: parent.verticalCenter
      checked: row.isActive
      busy: vpn.intent !== "" && row.profile && vpn.lastAttemptName === row.profile.name
      foreground: root.foreground
      cursorRing: false
      onToggled: vpn.activate(row.isActive
                              ? Object.assign({}, row.profile, { state: "active" })
                              : Object.assign({}, row.profile, { state: "inactive" }))
    }

    // Management is rarely what you came for, so it recedes until the row is
    // under the pointer. Dimmed rather than hidden: a control you cannot see is
    // fine, a control you cannot reach is not, and hover is not something this
    // widget gets to assume.
    Row {
      id: rowActions
      anchors.right: rowSwitch.left
      anchors.rightMargin: Style.space(6)
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(2)
      opacity: (row.hovered || row.hasCursor) ? 1 : 0.3

      Behavior on opacity {
        NumberAnimation { duration: 120; easing.type: Easing.OutCubic }
      }

      PanelActionButton {
        opacity: row.rowCaps.canAutostart ? 1 : 0
        enabled: row.rowCaps.canAutostart
        // A filled tick-box against an empty one survives 13 px; the previous
        // pair rendered as two unrelated blobs at this size.
        iconText: row.profile && row.profile.autostart ? "󰄲" : "󰄱"
        tooltipText: row.profile && row.profile.autostart ? "Disable autostart" : "Enable autostart"
        foreground: row.profile && row.profile.autostart ? root.foreground : root.dim
        hoverColor: root.foreground
        fontFamily: root.fontFamily
        onClicked: row.autostartToggled()
      }
      PanelActionButton {
        opacity: row.rowCaps.canCredentials ? 1 : 0
        enabled: row.rowCaps.canCredentials
        iconText: "󰌆"
        tooltipText: "Set credentials"
        foreground: row.profile && row.profile.hasAuth ? root.foreground : root.dim
        hoverColor: root.foreground
        fontFamily: root.fontFamily
        onClicked: row.credentialsRequested()
      }
      PanelActionButton {
        iconText: "󰩹"
        tooltipText: "Remove profile"
        foreground: root.dim
        hoverColor: root.urgent
        fontFamily: root.fontFamily
        onClicked: row.removeRequested()
      }
    }

    Column {
      anchors.left: dot.right
      anchors.leftMargin: Style.space(10)
      anchors.right: rowActions.left
      anchors.rightMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
      spacing: 0

      Text {
        width: parent.width
        text: (row.profile ? row.profile.name : "")
              + (!vpn.unified && row.isCurrent ? "  ·  bar profile" : "")
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        elide: Text.ElideRight
      }
      Text {
        width: parent.width
        visible: text !== ""
        text: {
          if (!row.profile) return ""
          var bits = []
          // For portals the name is the host, so printing both reads as a stutter.
          if (row.profile.remote && row.profile.remote !== row.profile.name)
            bits.push(row.profile.remote + (row.profile.port ? ":" + row.profile.port : ""))
          if (vpn.unified) bits.unshift(Model.backendBadge(row.profile))
          else if (row.profile.origin === "nm") bits.push("NetworkManager")
          // Spelled out, so the state is readable without decoding a glyph.
          if (row.profile.autostart) bits.push("autostart")
          if (!row.profile.hasAuth) bits.push("no credentials")
          return bits.join("  ·  ")
        }
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
      }
    }
  }
}
