import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Bar pill for the Sydney Train Planner. Shows a live countdown to the next
// departure on the saved default trip and opens the planner popup on click.
// Networking is done exactly like omarchy.weather: a `curl` Process per
// request, last-good data kept on failure.
BarWidget {
  id: root
  moduleName: "io.github.ozdadirri.sydney-train-planer"

  // ---- settings (inline on the shell.json entry) + on-disk config ----------
  readonly property var cfg: settings || ({})
  readonly property string apiKey: String(cfg.apiKey || fileCfg.apiKey || "")
  readonly property int resultCount: Math.max(1, Math.min(8, parseInt(cfg.results, 10) || 4))
  readonly property int refreshSeconds: Math.max(20, parseInt(cfg.refreshSeconds, 10) || 60)

  // Effective default trip: an in-panel pick (persisted to fileCfg) wins,
  // otherwise the values typed into the plugin settings form.
  readonly property string originId: fileCfg.originId || String(cfg.originId || "")
  readonly property string originName: fileCfg.originName || String(cfg.originName || "")
  readonly property string destinationId: fileCfg.destinationId || String(cfg.destinationId || "")
  readonly property string destinationName: fileCfg.destinationName || String(cfg.destinationName || "")
  readonly property bool hasDefaultTrip: originId !== "" && destinationId !== ""

  // ---- runtime state -----------------------------------------------------
  property var trips: []               // parsed journeys for the default trip
  property date now: new Date()
  property bool opened: false
  property bool popoutSwitchClosing: false
  property string lastError: ""
  property date lastUpdated: new Date(0)

  readonly property var nextTrip: trips.length ? trips[0] : null
  readonly property string pillIcon: ""   // nf-md-train

  function open() { opened = true }
  function close() { opened = false }
  function togglePanel() { opened = !opened }
  function closeForPopoutSwitch() {
    popoutSwitchClosing = true
    close()
    Qt.callLater(function() { root.popoutSwitchClosing = false })
  }

  function pillText() {
    if (vertical) return pillIcon
    if (!apiKey) return pillIcon + " set key"
    if (!hasDefaultTrip) return pillIcon + " plan"
    if (!nextTrip) return pillIcon + " …"
    var s = pillIcon + " " + Model.countdownLabel(nextTrip, now)
    var d = Model.delayLabel(nextTrip)
    if (d !== "") s += " " + d
    if (nextTrip.lines && nextTrip.lines.length) s += " · " + nextTrip.lines[0]
    return s
  }

  function pillColor() {
    if (!nextTrip) return root.bar ? root.bar.foreground : Color.foreground
    switch (Model.punctuality(nextTrip)) {
    case "late": return Color.urgent
    case "early": return Color.accent
    default: return root.bar ? root.bar.foreground : Color.foreground
    }
  }

  function refresh() {
    if (!apiKey || !hasDefaultTrip) { trips = []; return }
    if (tripProc.running) return
    var d = new Date()
    tripProc.command = Model.curlArgs(
      Model.tripUrl(originId, destinationId,
        Qt.formatDate(d, "yyyyMMdd"), Qt.formatTime(d, "HHmm")),
      apiKey, 10)
    tripProc.running = true
  }

  function pinTrip(origin, destination) {
    fileCfg.originId = origin.id
    fileCfg.originName = origin.name
    fileCfg.destinationId = destination.id
    fileCfg.destinationName = destination.name
    configFile.writeAdapter()
    Qt.callLater(root.refresh)
  }

  // ---- on-disk config: ~/.local/state/omarchy/settings/syd-train.json -----
  FileView {
    id: configFile
    path: Quickshell.env("HOME") + "/.local/state/omarchy/settings/syd-train.json"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onAdapterUpdated: writeAdapter()
    JsonAdapter {
      id: fileCfg
      property string apiKey: ""
      property string originId: ""
      property string originName: ""
      property string destinationId: ""
      property string destinationName: ""
    }
  }

  Process {
    id: tripProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var raw = String(text || "").trim()
        if (!raw) return
        var parsed = Model.parseTrip(raw)
        if (parsed.length) {
          root.trips = parsed
          root.lastError = ""
          root.lastUpdated = new Date()
        }
      }
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var e = String(text || "").trim()
        if (e) root.lastError = e
      }
    }
  }

  Timer {
    interval: root.refreshSeconds * 1000
    repeat: true
    running: true
    triggeredOnStart: true
    onTriggered: {
      root.now = new Date()
      root.refresh()
    }
  }

  // Tick the countdown every 15s without a network hit.
  Timer {
    interval: 15000
    repeat: true
    running: true
    onTriggered: root.now = new Date()
  }

  onApiKeyChanged: refresh()
  onOriginIdChanged: refresh()
  onDestinationIdChanged: refresh()

  visible: true
  implicitWidth: pill.implicitWidth
  implicitHeight: pill.implicitHeight

  WidgetButton {
    id: pill
    anchors.fill: parent
    bar: root.bar
    text: root.pillText()
    foreground: root.pillColor()
    active: root.opened
    horizontalMargin: 7
    tooltipText: root.hasDefaultTrip
      ? (root.originName + " → " + root.destinationName + "\nClick: plan · Middle: refresh · Right: notify")
      : "Sydney Train Planner — click to plan a trip"

    onPressed: function(button) {
      if (button === Qt.MiddleButton) root.refresh()
      else if (button === Qt.RightButton) {
        if (root.bar && root.nextTrip)
          root.bar.run("omarchy-notification-send 'Next: " + Model.countdownLabel(root.nextTrip, root.now)
            + " " + (root.nextTrip.lines.length ? root.nextTrip.lines[0] : "") + "'")
      } else root.togglePanel()
    }
  }

  // --- outside-click dismissal (same approach as celestune-bar) ------------
  Repeater {
    model: root.bar ? root.bar.clickTargets : []
    delegate: Item {
      id: obs
      required property var modelData
      width: 0; height: 0; visible: false
      Connections {
        target: obs.modelData
        ignoreUnknownSignals: true
        function onPressed(button) {
          if (root.opened && obs.modelData !== pill) root.close()
        }
      }
    }
  }

  Connections {
    target: root.bar
    ignoreUnknownSignals: true
    function onActivePopoutChanged() {
      if (root.opened && root.bar && root.bar.activePopout && root.bar.activePopout !== root)
        root.close()
    }
  }

  PopupCard {
    id: popup
    anchorItem: root
    bar: root.bar
    owner: root
    open: root.opened
    centerOnBar: true
    contentWidth: popup.fittedContentWidth(Style.space(480))
    contentHeight: popup.fittedContentHeight(planner.implicitHeight)

    Planner {
      id: planner
      anchors.fill: parent
      bar: root.bar
      apiKey: root.apiKey
      now: root.now
      resultCount: root.resultCount
      originSeedId: root.originId
      originSeedName: root.originName
      destSeedId: root.destinationId
      destSeedName: root.destinationName
      lastUpdated: root.lastUpdated
      onPinned: function(origin, destination) { root.pinTrip(origin, destination) }
    }
  }
}
