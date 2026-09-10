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
  moduleName: "hriddho.mullion"

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

  // Healthy: a window mark, which is the settings affordance. Otherwise the
  // state's own glyph, and clicking fixes rather than opens settings.
  readonly property string glyph: state === "healthy" ? "\uf2d0"
    : state === "missing" ? "\uf0e7" : "\uf021"

  readonly property string tooltip: {
    if (busy) return "Working on the title bars..."
    if (state === "missing") return "macOS title bars are not set up yet.\nClick to install them."
    if (state === "unloaded") return "Title bars stopped loading, usually after a Hyprland update.\nClick to rebuild them."
    return "Mullion settings"
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

  // Always present, because it is the way into the settings. The glyph and
  // tooltip still carry the health state.
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  property bool settingsOpen: false
  // Current values, read back from mullion-set so the panel always shows
  // what is really in the file rather than a guess.
  property var values: ({})

  function valueOf(key, fallback) {
    var raw = values[key]
    if (raw === undefined) return fallback
    if (raw === "true") return true
    if (raw === "false") return false
    var num = Number(raw)
    return isNaN(num) ? raw : num
  }

  function loadSettings() { if (!readProc.running) readProc.running = true }

  function put(key, value) {
    var next = {}
    for (var k in values) next[k] = values[k]
    next[key] = String(value)
    values = next
    writeProc.command = [root.helper("mullion-set"), key + "=" + String(value)]
    writeProc.running = true
  }

  function helper(name) { return Quickshell.env("HOME") + "/.local/bin/" + name }

  Process {
    id: readProc
    command: [root.helper("mullion-set"), "--list"]
    stdout: StdioCollector {
      onStreamFinished: {
        var parsed = {}
        var lines = String(text).split("\n")
        for (var i = 0; i < lines.length; i++) {
          var eq = lines[i].indexOf("=")
          if (eq > 0) parsed[lines[i].slice(0, eq).trim()] = lines[i].slice(eq + 1).trim()
        }
        root.values = parsed
      }
    }
  }

  Process { id: writeProc }
  Process { id: actionProc }

  IpcHandler {
    target: "hriddho.mullion"

    function refresh(): void {
      root.broadcast("refresh")
    }

    // So the panel can be opened from a keybinding or the terminal, not only
    // by clicking the bar icon.
    function settings(): void {
      root.loadSettings()
      root.settingsOpen = !root.settingsOpen
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

  // The mark: a rounded window whose left pane is filled -- the two things
  // this plugin does, dress a window's frame and split the screen. Drawn
  // rather than borrowed from an icon font, so it collides with nothing else
  // in anyone's bar, and it inks itself from the theme like every other icon.
  Component {
    id: markComponent

    Canvas {
      id: mark
      readonly property color ink: button.foreground !== undefined
        ? button.foreground : Color.foreground

      onInkChanged: mark.requestPaint()
      onWidthChanged: mark.requestPaint()

      onPaint: {
        var ctx = getContext("2d")
        ctx.reset()
        if (width <= 0 || height <= 0) return

        // Landscape, because a window is wider than it is tall. The icon slot
        // is square, so the frame is inset vertically to get there.
        var w = Math.round(width * 0.80)
        var h = Math.round(w * 0.76)
        var pad = Math.round((width - w) / 2)
        var top = Math.round((height - h) / 2)
        var r = Math.max(1, Math.round(w * 0.18))
        var split = pad + Math.round(w * 0.38)

        ctx.strokeStyle = ink
        ctx.fillStyle = ink
        ctx.lineWidth = Math.max(1, Math.round(width * 0.075))

        function frame() {
          ctx.beginPath()
          ctx.moveTo(pad + r, top)
          ctx.lineTo(pad + w - r, top)
          ctx.quadraticCurveTo(pad + w, top, pad + w, top + r)
          ctx.lineTo(pad + w, top + h - r)
          ctx.quadraticCurveTo(pad + w, top + h, pad + w - r, top + h)
          ctx.lineTo(pad + r, top + h)
          ctx.quadraticCurveTo(pad, top + h, pad, top + h - r)
          ctx.lineTo(pad, top + r)
          ctx.quadraticCurveTo(pad, top, pad + r, top)
          ctx.closePath()
        }

        frame()
        ctx.stroke()

        // Filled left pane: the snapped half.
        ctx.save()
        frame()
        ctx.clip()
        ctx.fillRect(pad, top, split - pad, h)
        ctx.restore()
      }
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    // Healthy state draws its own mark below rather than borrowing a font
    // glyph, so the icon is this plugin's and nobody else's. The unhealthy
    // states keep a glyph, because they need to read as a warning.
    text: root.busy ? "\uf110" : (root.state === "healthy" ? "" : root.glyph)
    // BarIconButton's own extension point: when set, it renders this in place
    // of a font glyph, correctly sized and optically centred for the bar.
    iconComponent: (root.state === "healthy" && !root.busy) ? markComponent : null
    slotSize: Style.bar.statusSlot
    fontSize: Style.font.caption
    tooltipText: root.tooltip
    onPressed: {
      if (root.state === "healthy" || root.state === "checking") {
        root.settingsOpen = !root.settingsOpen
        if (root.settingsOpen) root.loadSettings()
      } else {
        root.fix()
      }
    }
  }

  // ---------------------------------------------------------------------
  // Drag-to-edge snap preview.
  //
  // mullion-drag-snap follows the cursor while a window is being dragged and
  // pushes the target rectangle here, so you see where the window will land
  // before letting go. The rectangle is computed by mullion-snap itself, so the
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
    target: "mullion-preview"

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
    WlrLayershell.namespace: "mullion-preview"
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

  // ---------------------------------------------------------------------
  // Settings.
  //
  // Every colour, size and font here comes from the shell's Style and Color
  // tokens, which are generated from the active Omarchy theme. Nothing is
  // hardcoded, so the panel restyles itself when the theme changes and follows
  // the user's font size without being told.
  //
  // Controls write through mullion-set, the same command the terminal uses,
  // so the panel and the file can never disagree.
  PopupCard {
    id: settings
    anchorItem: root
    owner: root
    bar: root.bar
    open: root.settingsOpen
    contentWidth: settings.fittedContentWidth(Style.space(330))
    contentHeight: settings.fittedContentHeight(column.implicitHeight)
    onOpenChanged: if (!open) root.settingsOpen = false

    Column {
      id: column
      anchors.fill: parent
      spacing: Style.space(6)

      Text {
        text: "Mullion"
        color: Color.foreground
        font.family: Style.font.family
        font.pixelSize: Style.font.subtitle
        font.bold: true
      }

      PanelSectionHeader { text: "Window controls" }

      // Which platform's controls to wear. Snapping, split screen and
      // edge-resize are identical whichever is chosen, so they are not
      // mentioned here.
      Row {
        width: column.width
        spacing: Style.space(6)

        Repeater {
          model: [
            { key: "macos", label: "macOS" },
            { key: "windows", label: "Windows" },
            { key: "none", label: "None" }
          ]

          Button {
            required property var modelData
            width: (column.width - Style.space(12)) / 3
            text: modelData.label
            active: root.valueOf("window_style", "macos") === modelData.key
            bordered: true
            onClicked: root.put("window_style", modelData.key)
          }
        }
      }

      PanelSectionHeader { text: "Title bar" }

      MullionSlider {
        label: "Button size"; settingKey: "button_size"
        from: 8; to: 20; fallback: 12
      }
      MullionSlider {
        label: "Bar height"; settingKey: "bar_height"
        from: 20; to: 44; fallback: 28
      }
      MullionToggle {
        label: "Always show glyphs"; settingKey: "icons_always_visible"
        fallback: true
      }

      PanelSectionHeader { text: "Window" }

      MullionSlider {
        label: "Corner rounding"; settingKey: "rounding"
        from: 0; to: 24; fallback: 10
      }
      MullionSlider {
        label: "Border width"; settingKey: "border_size"
        from: 0; to: 8; fallback: 3
      }
      MullionToggle {
        label: "Open windows floating"; settingKey: "float_by_default"
        fallback: true
      }
      MullionToggle {
        label: "Drop shadow"; settingKey: "shadow"; fallback: true
      }

      PanelSectionHeader { text: "Snapping" }

      MullionToggle {
        label: "Drag to edge to snap"; settingKey: "drag_snap"; fallback: true
      }
      MullionSlider {
        label: "Edge sensitivity"; settingKey: "snap_edge"
        from: 4; to: 40; fallback: 10
      }

      PanelSectionHeader { text: "Other applications" }

      MullionToggle {
        label: "Hide their window buttons"
        settingKey: "hide_app_window_buttons"
        fallback: true
        hint: "Chromium, GNOME apps and Firefox each draw their own close\nbutton. Off hands those buttons back."
      }

      Item { width: 1; height: Style.space(4) }

      Button {
        width: parent.width
        text: "Rebuild title bars"
        bordered: true
        onClicked: {
          actionProc.command = ["omarchy-launch-floating-terminal-with-presentation",
                                root.helper("rebuild-hyprbars")]
          actionProc.running = true
          root.settingsOpen = false
        }
      }
    }
  }

  // A labelled row with a slider, bound to one settings key.
  component MullionSlider: Item {
    property string label: ""
    property string settingKey: ""
    property real from: 0
    property real to: 10
    property real fallback: 0
    readonly property real current: root.valueOf(settingKey, fallback)

    width: column.width
    implicitHeight: Math.max(Style.spacing.controlHeight, rowLabel.implicitHeight)

    Text {
      id: rowLabel
      anchors.verticalCenter: parent.verticalCenter
      text: parent.label
      color: Color.foreground
      font.family: Style.font.family
      font.pixelSize: Style.font.body
    }

    Text {
      id: rowValue
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      text: Math.round(parent.current)
      color: Color.accent
      font.family: Style.font.family
      font.pixelSize: Style.font.bodySmall
      width: Style.space(24)
      horizontalAlignment: Text.AlignRight
    }

    PanelSlider {
      anchors.right: rowValue.left
      anchors.rightMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(120)
      bar: root.bar
      integer: true
      minimum: parent.from
      maximum: parent.to
      step: 1
      value: parent.current
      onMoved: root.put(parent.settingKey, Math.round(value))
    }
  }

  // A labelled row with an on/off control, bound to one settings key.
  component MullionToggle: Item {
    property string label: ""
    property string settingKey: ""
    property bool fallback: true
    property string hint: ""
    readonly property bool current: root.valueOf(settingKey, fallback) === true

    width: column.width
    implicitHeight: Math.max(Style.spacing.controlHeight, toggleLabel.implicitHeight)

    Text {
      id: toggleLabel
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      width: parent.width - Style.space(60)
      text: parent.label
      elide: Text.ElideRight
      color: Color.foreground
      font.family: Style.font.family
      font.pixelSize: Style.font.body
    }

    Button {
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      text: parent.current ? "On" : "Off"
      active: parent.current
      bordered: true
      tooltipText: parent.hint
      onClicked: root.put(parent.settingKey, parent.current ? "false" : "true")
    }
  }
}
