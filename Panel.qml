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
  moduleName: "io.github.robinnepomukmai.openvpn"
  ipcTarget: "io.github.robinnepomukmai.openvpn"
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
  property int profileIndex: 0
  property bool cursorActive: false

  readonly property string barTooltip: {
    var base = "VPN " + vpn.profile + " " + vpn.stateLabel
    if (vpn.connected) return base + " · " + vpn.address
    if (vpn.failed) return base + " · right-click to retry"
    return base + " · right-click to connect"
  }

  readonly property var currentProfile: {
    for (var i = 0; i < vpn.profiles.length; i++)
      if (vpn.profiles[i].name === vpn.profile) return vpn.profiles[i]
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
  }

  function moveCursor(dy) {
    cursorActive = true
    if (vpn.profiles.length === 0) return
    profileIndex = Math.max(0, Math.min(vpn.profiles.length - 1, profileIndex + dy))
  }

  function activateCursor() {
    if (!cursorActive || vpn.profiles.length === 0) return
    var p = vpn.profiles[profileIndex]
    if (p) p.name === vpn.profile ? vpn.toggle() : vpn.switchTo(p.name, "up")
  }

  Service {
    id: vpn
    settings: root.settings
    detailed: root.opened
  }

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
        root.credentialsProfile = ""
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
      text: "󰖂  ↓" + Model.rate(vpn.rxRate) + " ↑" + Model.rate(vpn.txRate)
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
        else if (key === "n") vpn.pickConfigFile()
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
              title: "OpenVPN"
              meta: vpn.profile + " · " + vpn.stateLabel
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
              trailingControl: Component {
                ToggleSwitch {
                  checked: vpn.connected || vpn.busy
                  busy: vpn.busy
                  foreground: root.foreground
                  onToggled: vpn.toggle()
                }
              }
            }
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

          // ── Connection ──────────────────────────────────────────────────
          Column {
            visible: vpn.connected || vpn.busy
            width: parent.width
            spacing: Style.spacing.labelGap

            PanelSectionHeader {
              text: "CONNECTION"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            InfoPair {
              label: "Server"
              value: vpn.server || (root.currentProfile ? root.currentProfile.remote : "") || "—"
            }
            InfoPair {
              label: "Protocol"
              value: root.currentProfile && root.currentProfile.proto
                     ? root.currentProfile.proto.toUpperCase()
                       + (root.currentProfile.port ? " / " + root.currentProfile.port : "")
                     : "—"
            }
            InfoPair { label: "Cipher"; value: vpn.cipher || "—" }
            InfoPair { label: "Tunnel IP"; value: vpn.address || "—" }
            InfoPair {
              label: "Interface"
              value: vpn.iface ? vpn.iface + (vpn.mtu ? " · MTU " + vpn.mtu : "") : "—"
            }
            InfoPair { label: "Uptime"; value: vpn.since > 0 ? Model.duration(vpn.uptimeSeconds) : "—" }

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
              rxColor: root.foreground
              txColor: root.foreground
            }

            Row {
              width: parent.width
              spacing: Style.space(16)

              Text {
                text: "↓ " + Model.rate(vpn.rxRate) + "B/s"
                color: root.foreground
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
                text: Model.bytes(vpn.rxBytes) + " ↓  " + Model.bytes(vpn.txBytes) + " ↑"
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
              text: "PROFILES"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Text {
              visible: !vpn.helperInstalled
              width: parent.width
              text: "Profile management is not set up — run system/install.sh from the plugin "
                    + "directory with sudo. Everything else works without it."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap
            }

            Text {
              visible: vpn.helperInstalled && vpn.profiles.length === 0
              width: parent.width
              text: "No profiles in /etc/openvpn/client."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }

            Repeater {
              model: vpn.profiles

              ProfileRow {
                width: column.width
                hasCursor: root.cursorActive && root.profileIndex === index
                onActivated: profile.name === vpn.profile ? vpn.toggle() : vpn.switchTo(profile.name, "up")
                onAutostartToggled: vpn.setAutostart(profile.name, !profile.autostart)
                onCredentialsRequested: { root.closeForms(); root.credentialsProfile = profile.name }
                onRemoveRequested: { root.closeForms(); root.removeTarget = profile.name }
                onHoveredChanged: if (hovered) { root.cursorActive = true; root.profileIndex = index }
              }
            }
          }

          // ── Actions ─────────────────────────────────────────────────────
          Row {
            visible: vpn.helperInstalled
            width: parent.width
            spacing: Style.spacing.controlGap

            Button {
              text: "Add config"
              iconText: "󰐕"
              bordered: true
              foreground: root.foreground
              fontFamily: root.fontFamily
              onClicked: { root.closeForms(); vpn.pickConfigFile() }
            }
            Button {
              text: "Refresh"
              iconText: "󰑐"
              bordered: true
              foreground: root.foreground
              fontFamily: root.fontFamily
              onClicked: { vpn.refresh(); vpn.refreshDetails(); vpn.refreshProfiles() }
            }
          }

          // ── Import form ─────────────────────────────────────────────────
          Column {
            visible: root.importPath !== ""
            width: parent.width
            spacing: Style.space(6)

            PanelSeparator { foreground: root.foreground }
            PanelSectionHeader {
              text: "IMPORT"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }
            Text {
              width: parent.width
              text: root.importPath
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              elide: Text.ElideMiddle
            }
            TextField {
              width: parent.width
              text: root.importName
              placeholderText: "Profile name"
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
                foreground: root.foreground
                fontFamily: root.fontFamily
                onClicked: vpn.importConfig(root.importPath, root.importName)
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
            visible: root.credentialsProfile !== ""
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

          // ── Remove confirmation ─────────────────────────────────────────
          Column {
            visible: root.removeTarget !== ""
            width: parent.width
            spacing: Style.space(6)

            PanelSeparator { foreground: root.foreground }
            Text {
              width: parent.width
              text: "Remove profile “" + root.removeTarget + "” and its stored credentials?"
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
                onClicked: vpn.removeProfile(root.removeTarget)
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
    property bool hasCursor: false
    readonly property alias hovered: rowMouse.containsMouse
    readonly property bool isCurrent: profile && profile.name === vpn.profile
    readonly property bool isActive: profile && profile.state === "active"

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

    // Filled while the tunnel is up, outline only otherwise.
    Rectangle {
      id: dot
      anchors.left: parent.left
      anchors.leftMargin: Style.space(6)
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(7)
      height: width
      radius: width / 2
      color: row.isActive ? root.foreground : "transparent"
      border.width: 1
      border.color: row.isActive ? root.foreground
                                 : Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.4)
    }

    // Declared after the MouseArea so the buttons swallow the row click.
    Row {
      id: rowActions
      anchors.right: parent.right
      anchors.rightMargin: Style.space(4)
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(2)

      PanelActionButton {
        iconText: row.profile && row.profile.autostart ? "󰐫" : "󰐪"
        tooltipText: row.profile && row.profile.autostart ? "Disable autostart" : "Enable autostart"
        foreground: row.profile && row.profile.autostart ? root.foreground : root.dim
        hoverColor: root.foreground
        fontFamily: root.fontFamily
        onClicked: row.autostartToggled()
      }
      PanelActionButton {
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
        text: (row.profile ? row.profile.name : "") + (row.isCurrent ? "  ·  bar profile" : "")
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
          if (row.profile.remote)
            bits.push(row.profile.remote + (row.profile.port ? ":" + row.profile.port : ""))
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
