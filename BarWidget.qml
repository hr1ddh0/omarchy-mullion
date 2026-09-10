import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Ui

// Health indicator for the macOS-style title bars.
//
// The title bars are drawn by hyprbars, a compiled Hyprland plugin. A compiled
// plugin is tied to the exact Hyprland build it was compiled against, so an
// update that bumps Hyprland makes the bars silently stop appearing -- nothing
// errors, they are just gone, and it is not obvious why.
//
// This widget watches for that. It stays hidden while everything works, and
// surfaces a one-click fix when it doesn't.
BarWidget {
  id: root
  moduleName: "hriddho.cupertino"

  // "checking" until the first probe returns, so we never flash a warning
  // during startup before we know anything.
  //   healthy   - plugin built and loaded, title bars are drawn
  //   unloaded  - built but not loaded (usually: Hyprland was updated)
  //   missing   - never built on this machine
  property string state: "checking"
  property bool busy: false

  readonly property int checkIntervalMinutes: Math.max(1, Number(setting("checkIntervalMinutes", 10)))
  readonly property bool alwaysShow: setting("alwaysShow", false) === true

  // Directory this plugin was loaded from, so the scripts shipped beside this
  // file can be found wherever the user cloned or installed it.
  readonly property string pluginDir: {
    var url = String(Qt.resolvedUrl("."))
    var path = url.indexOf("file://") === 0 ? url.substring(7) : url
    return path.charAt(path.length - 1) === "/" ? path : path + "/"
  }

  readonly property string glyph: state === "missing" ? "\uf2d0" : "\uf021"

  readonly property string tooltip: {
    if (busy) return "Working on the title bars..."
    if (state === "missing") return "macOS title bars are not set up yet.\nClick to install them."
    if (state === "unloaded") return "Title bars stopped loading, usually after a Hyprland update.\nClick to rebuild them."
    return "macOS title bars are working."
  }

  function refresh() {
    if (!probe.running) probe.running = true
  }

  function fix() {
    if (busy || state === "healthy" || state === "checking") return
    if (!root.bar) return

    // Absolute paths: this runs in a fresh terminal whose PATH we don't own.
    var target = state === "missing"
      ? pluginDir + "install.sh"
      : "$HOME/.local/bin/rebuild-hyprbars"

    root.busy = true
    // Both scripts change system state, so run them in a visible terminal
    // rather than silently in the background.
    root.bar.run("omarchy-launch-floating-terminal-with-presentation " + JSON.stringify(target))

    // Re-probe on a delay; a rebuild compiles, which takes a moment.
    recheck.restart()
  }

  visible: alwaysShow || (state !== "healthy" && state !== "checking")
  implicitWidth: visible ? button.implicitWidth : 0
  implicitHeight: visible ? button.implicitHeight : 0

  IpcHandler {
    target: "hriddho.cupertino"

    function refresh(): void {
      root.broadcast("refresh")
    }
  }

  // Exit code carries the answer so we never have to parse stdout:
  //   0 loaded, 1 built but not loaded, 2 not built
  Process {
    id: probe
    command: ["bash", "-lc",
      "if hyprctl plugin list 2>/dev/null | grep -q hyprbars; then exit 0; "
      + "elif [ -f \"$HOME/.local/share/hyprland/plugins/hyprbars.so\" ]; then exit 1; "
      + "else exit 2; fi"]
    onExited: function(exitCode) {
      if (exitCode === 0) root.state = "healthy"
      else if (exitCode === 1) root.state = "unloaded"
      else root.state = "missing"
      root.busy = false
    }
  }

  Timer {
    id: poll
    interval: root.checkIntervalMinutes * 60000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  // After a fix attempt, look again a few times rather than waiting out the
  // full poll interval, so the widget clears itself as soon as it is fixed.
  Timer {
    id: recheck
    interval: 15000
    repeat: true
    property int ticks: 0
    onRunningChanged: if (running) ticks = 0
    onTriggered: {
      ticks++
      root.refresh()
      if (ticks >= 8 || root.state === "healthy") {
        stop()
        root.busy = false
      }
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.busy ? "\uf110" : root.glyph
    slotSize: Style.bar.statusSlot
    fontSize: Style.font.caption
    tooltipText: root.tooltip
    onPressed: root.fix()
  }

  // ---------------------------------------------------------------------
  // Drag-to-edge snap preview.
  //
  // macos-drag-snap follows the cursor while a window is being dragged and
  // pushes the target rectangle here, so you see where the window will land
  // before letting go. The rectangle is computed by macos-snap itself, so the
  // preview can never disagree with the snap that follows.
  //
  // The bar builds one widget per monitor but an IPC target routes to a single
  // handler, so the receiving instance fans the box out to its peers.
  property var snapBox: null

  function setBox(box) {
    root.snapBox = (box && box.w > 0 && box.h > 0) ? box : null
  }

  function fanoutBox(box) {
    var items = (bar && typeof bar.moduleWidgets === "function")
      ? bar.moduleWidgets(moduleName) : [root]
    for (var i = 0; i < items.length; i++) {
      if (items[i] && typeof items[i].setBox === "function") items[i].setBox(box)
    }
  }

  IpcHandler {
    target: "cupertino-snap"

    function show(payloadJson: string): string {
      var box = null
      try { box = JSON.parse(payloadJson) } catch (e) { box = null }
      root.fanoutBox(box)
      return "ok"
    }

    function hide(): string {
      root.fanoutBox(null)
      return "ok"
    }

    function ping(): string { return "ok" }
  }

  PanelWindow {
    id: snapPreview
    visible: root.snapBox !== null

    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "cupertino-snap"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
    exclusionMode: ExclusionMode.Ignore
    // Purely visual: an empty input region means this can never swallow the
    // drag that is currently in progress.
    mask: Region {}

    Rectangle {
      // Box coordinates are global, so shift them into this screen's space.
      readonly property int originX: snapPreview.screen ? snapPreview.screen.x : 0
      readonly property int originY: snapPreview.screen ? snapPreview.screen.y : 0

      x: root.snapBox ? root.snapBox.x - originX : 0
      y: root.snapBox ? root.snapBox.y - originY : 0
      width: root.snapBox ? root.snapBox.w : 0
      height: root.snapBox ? root.snapBox.h : 0

      radius: Style.cornerRadius
      color: Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.20)
      border.color: Color.accent
      border.width: 2
      opacity: root.snapBox ? 1 : 0

      Behavior on x { NumberAnimation { duration: 110; easing.type: Easing.OutCubic } }
      Behavior on y { NumberAnimation { duration: 110; easing.type: Easing.OutCubic } }
      Behavior on width { NumberAnimation { duration: 110; easing.type: Easing.OutCubic } }
      Behavior on height { NumberAnimation { duration: 110; easing.type: Easing.OutCubic } }
      Behavior on opacity { NumberAnimation { duration: 90 } }
    }
  }
}
