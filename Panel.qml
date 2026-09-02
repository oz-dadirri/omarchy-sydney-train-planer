import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Trip-planner popup. Built on KeyboardPanel (not PopupCard) so the origin /
// destination text fields accept keyboard input, the same reason the built-in
// weather plugin uses KeyboardPanel for its location search.
Panel {
  id: root
  moduleName: "io.github.ozdadirri.sydney-train-planer"
  ipcTarget: "io.github.ozdadirri.sydney-train-planer"
  manageIpc: false

  // Injected by BarWidget.qml.
  property var anchorItem: null
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root
  property bool openedFromHotkey: false

  // Emitted when a journey is tapped; BarWidget persists it as the default.
  signal pinned(var origin, var destination)

  // ---- config (own read of the shared state file) ------------------------
  readonly property string apiKey: String(fileCfg.apiKey || "")
  readonly property int resultCount: 4

  FileView {
    path: Quickshell.env("HOME") + "/.local/state/omarchy/settings/syd-train.json"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    JsonAdapter {
      id: fileCfg
      property string apiKey: ""
      property string originId: ""
      property string originName: ""
      property string destinationId: ""
      property string destinationName: ""
    }
  }

  // ---- panel lifecycle --------------------------------------------------
  function open() {
    openedFromHotkey = false
    setCenterHoverRevealSuppressed(false)
    root.controller.show()
    seedFromConfig()
  }
  function openFromHotkey() {
    openedFromHotkey = true
    root.controller.show()
    seedFromConfig()
    Qt.callLater(function() { if (root.opened) setCenterHoverRevealSuppressed(true) })
  }
  function close() {
    setCenterHoverRevealSuppressed(false)
    root.controller.hide()
  }
  function toggle() {
    if (root.opened) root.close()
    else root.openFromHotkey()
  }
  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }
  function setCenterHoverRevealSuppressed(value) {
    if (root.bar && "centerHoverRevealSuppressed" in root.bar)
      root.bar.centerHoverRevealSuppressed = value
  }

  // ---- planner state --------------------------------------------------
  property var originStop: ({ id: "", name: "" })
  property var destStop: ({ id: "", name: "" })
  readonly property bool ready: originStop.id !== "" && destStop.id !== "" && apiKey !== ""

  property var trips: []
  property string status: ""
  property bool locating: false
  property date lastUpdated: new Date(0)
  property date now: new Date()

  property string activeField: ""     // "origin" | "dest" | ""
  property var suggestions: []
  property string _pendingQuery: ""
  property string _pendingField: ""

  function seedFromConfig() {
    if (originStop.id === "" && fileCfg.originId !== "") {
      originStop = { id: fileCfg.originId, name: fileCfg.originName }
      originField.text = fileCfg.originName
    }
    if (destStop.id === "" && fileCfg.destinationId !== "") {
      destStop = { id: fileCfg.destinationId, name: fileCfg.destinationName }
      destField.text = fileCfg.destinationName
    }
    if (ready) planTrip()
  }

  function fmtTime(iso) {
    if (!iso) return "--:--"
    var d = new Date(iso)
    return isNaN(d.getTime()) ? "--:--" : Qt.formatTime(d, "h:mm AP")
  }
  function countdown(iso) {
    if (!iso) return ""
    var m = Math.round((new Date(iso).getTime() - root.now.getTime()) / 60000)
    if (m < 0) return "departed"
    if (m === 0) return "now"
    if (m < 60) return m + " min"
    return Math.floor(m / 60) + "h " + (m % 60) + "m"
  }

  function swap() {
    var o = originStop, d = destStop
    originStop = { id: d.id, name: d.name }
    destStop = { id: o.id, name: o.name }
    originField.text = originStop.name
    destField.text = destStop.name
    suggestions = []; activeField = ""
    planTrip()
  }

  function chooseSuggestion(item) {
    if (activeField === "origin") {
      originStop = { id: item.id, name: item.disassembledName || item.name }
      originField.text = originStop.name
    } else if (activeField === "dest") {
      destStop = { id: item.id, name: item.disassembledName || item.name }
      destField.text = destStop.name
    }
    suggestions = []; activeField = ""
    keyCatcher.forceActiveFocus()
    planTrip()
  }

  function queueSearch(q, field) {
    _pendingQuery = q; _pendingField = field
    debounce.restart()
  }
  function searchStops(query, field) {
    activeField = field
    if (String(query || "").trim().length < 3) { suggestions = []; return }
    stopProc.pending = query
    if (!stopProc.running) stopProc.fire()
  }

  function planTrip() {
    if (!ready) { trips = []; return }
    if (tripProc.running) return
    var d = new Date()
    status = "Loading…"
    tripProc.command = Model.curlArgs(
      Model.tripUrl(originStop.id, destStop.id,
        Qt.formatDate(d, "yyyyMMdd"), Qt.formatTime(d, "HHmm")),
      apiKey, 10)
    tripProc.running = true
  }

  function useCurrentLocation() {
    if (locating) return
    locating = true
    status = "Detecting your location…"
    geoProc.running = true
  }

  // ---- processes -----------------------------------------------------------
  Process {
    id: stopProc
    property string pending: ""
    property string active: ""
    function fire() {
      active = pending
      command = Model.curlArgs(Model.stopFinderUrl(active), root.apiKey, 6)
      running = true
    }
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.suggestions = Model.parseStopFinder(text)
        if (stopProc.pending !== stopProc.active) Qt.callLater(stopProc.fire)
      }
    }
  }

  Process {
    id: tripProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var parsed = Model.parseTrip(text)
        root.trips = parsed
        root.status = parsed.length ? "" : "No journeys found"
        if (parsed.length) root.lastUpdated = new Date()
      }
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var e = String(text || "").trim()
        if (e && !root.trips.length) root.status = "TfNSW request failed"
      }
    }
  }

  Process {
    id: geoProc
    command: ["curl", "-fsS", "--max-time", "6", "https://ipapi.co/json/"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.locating = false
        try {
          var j = JSON.parse(String(text || "{}"))
          if (j.latitude && j.longitude) {
            root.originStop = {
              id: Model.coordId(j.latitude, j.longitude),
              name: "Current location" + (j.city ? " (" + j.city + ")" : "")
            }
            originField.text = root.originStop.name
            root.status = ""
            root.planTrip()
            return
          }
        } catch (e) {}
        root.status = "Could not detect location"
      }
    }
  }

  Timer {
    id: debounce
    interval: 280
    onTriggered: root.searchStops(root._pendingQuery, root._pendingField)
  }

  Timer {
    interval: 15000
    repeat: true
    running: root.opened
    onTriggered: root.now = new Date()
  }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.openFromHotkey() }
    function close(): void { root.close() }
    function toggle(): void { root.toggle() }
    function show(): void { root.openFromHotkey() }
    function hide(): void { root.close() }
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    centerOnBar: true
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(480))
    contentHeight: panel.fittedContentHeight(content.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: originField.activeFocus || destField.activeFocus
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Column {
        id: content
        width: parent.width
        spacing: Style.space(10)

        // Header
        Item {
          width: parent.width
          height: headerRefresh.implicitHeight
          Text {
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            text: "SYDNEY TRAINS"
            color: Qt.darker(root.bar.foreground, 1.4)
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.bodySmall
            font.letterSpacing: 1
          }
          Button {
            id: headerRefresh
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            iconText: "󰑐"
            tooltipText: "Refresh"
            foreground: root.bar.foreground
            verticalPadding: 2
            horizontalPadding: 4
            onClicked: root.planTrip()
          }
        }

        // From
        Row {
          width: parent.width
          spacing: Style.space(8)
          Text {
            width: Style.space(44)
            text: "From"
            anchors.verticalCenter: parent.verticalCenter
            color: root.bar.foreground
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.body
          }
          TextField {
            id: originField
            width: parent.width - Style.space(44) - Style.space(8) - locBtn.width - Style.space(8)
            placeholderText: "Origin stop"
            foreground: root.bar.foreground
            onTextChanged: {
              if (text !== root.originStop.name) {
                root.originStop = { id: "", name: text }
                root.queueSearch(text, "origin")
              }
            }
            onActiveFocusChanged: if (activeFocus) root.activeField = "origin"
            Keys.onEscapePressed: { text = ""; keyCatcher.forceActiveFocus() }
          }
          Button {
            id: locBtn
            anchors.verticalCenter: parent.verticalCenter
            iconText: root.locating ? "󰦖" : ""
            iconSpinning: root.locating
            tooltipText: "Use current location"
            foreground: root.bar.foreground
            bordered: true
            onClicked: root.useCurrentLocation()
          }
        }

        // Swap
        Button {
          anchors.horizontalCenter: parent.horizontalCenter
          iconText: "󰓡"
          tooltipText: "Swap origin and destination"
          foreground: root.bar.foreground
          onClicked: root.swap()
        }

        // To
        Row {
          width: parent.width
          spacing: Style.space(8)
          Text {
            width: Style.space(44)
            text: "To"
            anchors.verticalCenter: parent.verticalCenter
            color: root.bar.foreground
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.body
          }
          TextField {
            id: destField
            width: parent.width - Style.space(44) - Style.space(8)
            placeholderText: "Destination stop"
            foreground: root.bar.foreground
            onTextChanged: {
              if (text !== root.destStop.name) {
                root.destStop = { id: "", name: text }
                root.queueSearch(text, "dest")
              }
            }
            onActiveFocusChanged: if (activeFocus) root.activeField = "dest"
            Keys.onEscapePressed: { text = ""; keyCatcher.forceActiveFocus() }
          }
        }

        // Suggestions
        Column {
          width: parent.width
          spacing: 0
          visible: root.suggestions.length > 0
          Repeater {
            model: root.suggestions
            Rectangle {
              required property var modelData
              required property int index
              width: parent.width
              height: sRow.implicitHeight + Style.space(10)
              radius: Style.cornerRadius
              color: sArea.containsMouse
                ? Style.hoverFillFor(root.bar.foreground, Color.accent) : "transparent"
              Row {
                id: sRow
                anchors.left: parent.left
                anchors.leftMargin: Style.space(10)
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(8)
                Text {
                  text: modelData.disassembledName || modelData.name
                  color: root.bar.foreground
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.body
                }
                Text {
                  text: modelData.type === "stop" ? "" : modelData.type
                  color: Qt.darker(root.bar.foreground, 1.5)
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  anchors.verticalCenter: parent.verticalCenter
                }
              }
              MouseArea {
                id: sArea
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.chooseSuggestion(modelData)
              }
            }
          }
        }

        Rectangle {
          width: parent.width
          height: Style.spacing.hairline
          color: root.bar.foreground
          opacity: 0.12
          visible: root.trips.length > 0 || root.status !== ""
        }

        Text {
          visible: root.status !== "" && root.trips.length === 0
          text: root.status
          color: Qt.darker(root.bar.foreground, 1.4)
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.bodySmall
          font.italic: true
        }

        // Journeys
        Repeater {
          model: root.trips.slice(0, root.resultCount)
          Rectangle {
            required property var modelData
            width: parent.width
            height: jCol.implicitHeight + Style.space(12)
            radius: Style.cornerRadius
            color: jArea.containsMouse
              ? Style.hoverFillFor(root.bar.foreground, Color.accent) : "transparent"

            Column {
              id: jCol
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.leftMargin: Style.space(6)
              anchors.rightMargin: Style.space(6)
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(2)

              Row {
                width: parent.width
                spacing: Style.space(10)
                Text {
                  width: Style.space(66)
                  text: root.countdown(modelData.depEstimated)
                  color: root.bar.foreground
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.body
                  font.bold: true
                }
                Text {
                  text: root.fmtTime(modelData.depEstimated) + " → " + root.fmtTime(modelData.arrEstimated)
                  color: root.bar.foreground
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.body
                }
                Text {
                  text: (modelData.durationMin != null ? "· " + modelData.durationMin + " min" : "")
                  color: Qt.darker(root.bar.foreground, 1.4)
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  anchors.verticalCenter: parent.verticalCenter
                }
              }
              Row {
                width: parent.width
                spacing: Style.space(8)
                Text {
                  width: Style.space(66)
                  text: (modelData.lines && modelData.lines.length) ? modelData.lines.join(" › ") : modelData.modes.join(", ")
                  color: Color.accent
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.bodySmall
                }
                Text {
                  visible: modelData.platform !== ""
                  text: "Plat " + modelData.platform
                  color: Qt.darker(root.bar.foreground, 1.5)
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.bodySmall
                }
                Text {
                  visible: modelData.changes > 0
                  text: modelData.changes + " chg"
                  color: Qt.darker(root.bar.foreground, 1.5)
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.bodySmall
                }
                Text {
                  visible: modelData.delayMin > 0
                  text: "+" + modelData.delayMin + " min late"
                  color: Color.urgent
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.bodySmall
                }
              }
            }
            MouseArea {
              id: jArea
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.pinned(root.originStop, root.destStop)
            }
          }
        }

        Text {
          visible: root.lastUpdated.getTime() > 0
          width: parent.width
          text: "Updated " + Qt.formatTime(root.lastUpdated, "h:mm:ss AP") + " · tap a journey to pin it to the bar"
          color: Qt.darker(root.bar.foreground, 1.5)
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.caption
        }
      }
    }
  }
}
