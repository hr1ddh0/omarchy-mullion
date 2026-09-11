pragma ComponentBehavior: Bound

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
  property string health: "checking"
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
  readonly property string glyph: health === "healthy" ? "\uf2d0"
    : health === "missing" ? "\uf0e7" : "\uf021"

  readonly property string tooltip: {
    if (busy) return "Setting up..."
    // Installing from the marketplace only clones this widget: `omarchy plugin
    // add` deliberately never runs code from a plugin. So on a fresh install
    // this is the state the user lands in, and it has to say plainly what is
    // missing and that one click finishes it.
    if (health === "missing") return "Mullion is not set up yet.\n"
      + "Click to install the title bars, snapping and settings.\n"
      + "It opens a terminal so you can see what it does."
    if (health === "unloaded") return "Title bars stopped loading, usually after a Hyprland update.\nClick to rebuild them."
    return "Mullion settings"
  }

  function refresh() {
    if (!probe.running) probe.running = true
  }

  function fix() {
    if (busy || health === "healthy" || health === "checking") return
    if (!root.bar) return

    // Absolute paths: this runs in a fresh terminal whose PATH we don't own.
    var target = health === "missing"
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

  // Bar.qml's findPanelWidget only treats a widget as panel-bearing when it
  // exposes open(), close() and a defined `opened` -- see the check in
  // plugins/bar/Bar.qml. Without this the shell's summon and hide routes
  // report "unknown", and it is also how the bar picks a single instance to
  // act on when one widget exists per monitor.
  readonly property bool opened: settingsOpen
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

  // The lifecycle Omarchy routes `omarchy-shell shell summon <id>` and
  // `shell hide <id>` to. Kept separate from the toggle so an explicit open
  // never closes an already-open panel.
  function open(payloadJson) {
    root.loadSettings()
    root.settingsOpen = true
  }

  function close() {
    root.settingsOpen = false
  }

  // broadcast() can only relay no-argument methods.
  function openSettings() {
    root.loadSettings()
    root.settingsOpen = true
  }

  // No-argument, so broadcast() can relay it to every instance.
  function toggleSettings() {
    root.settingsOpen = !root.settingsOpen
    if (root.settingsOpen) root.loadSettings()
  }

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
    //
    // Relayed with broadcast: the bar builds one widget per surface and an IPC
    // target only ever routes to one of them, so toggling this instance alone
    // would flip a copy whose popup nobody can see.
    function settings(): void {
      root.broadcast("toggleSettings")
    }

    // Relayed too: the instance owning the target is not necessarily the one
    // whose popup is on screen.
    function open(): void { root.broadcast("openSettings") }
    function close(): void { root.broadcast("close") }
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
      if (exitCode === 0) root.health = "healthy"
      else if (exitCode === 1) root.health = "unloaded"
      else root.health = "missing"
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
      if (ticks >= 8 || root.health === "healthy") {
        stop()
        root.busy = false
      }
    }
  }

  // The mark: a window divided by a mullion -- the bar between panes the
  // plugin is named for, and the thing it does most visibly, splitting a
  // screen between windows.
  //
  // It was a filled left pane, which is the standard "toggle sidebar" glyph in
  // editors and browsers; at this size people read that meaning, not this one.
  // A centred divider carries no such baggage, stays legible at 14px, and is
  // distinct from every other icon in the bar.
  //
  // Drawn rather than borrowed from an icon font, so it collides with nothing
  // in anyone else's bar, and it inks itself from the theme like the rest.
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
        // The mullion itself: centred, and at least a pixel wide so it never
        // disappears at small sizes or fractional scales.
        var barW = Math.max(1, Math.round(w * 0.12))
        var barX = pad + Math.round((w - barW) / 2)

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

        // The divider, clipped to the frame so it never bleeds past the
        // rounded corners.
        ctx.save()
        frame()
        ctx.clip()
        ctx.fillRect(barX, top, barW, h)
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
    text: root.busy ? "\uf110" : (root.health === "healthy" ? "" : root.glyph)
    // BarIconButton's own extension point: when set, it renders this in place
    // of a font glyph, correctly sized and optically centred for the bar.
    iconComponent: (root.health === "healthy" && !root.busy) ? markComponent : null
    slotSize: Style.bar.statusSlot
    fontSize: Style.font.caption
    tooltipText: root.tooltip
    onPressed: {
      if (root.health === "healthy" || root.health === "checking") {
        root.toggleSettings()
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
    id: settingsPanel
    anchorItem: root
    owner: root
    bar: root.bar
    open: root.settingsOpen
    contentWidth: settingsPanel.fittedContentWidth(Style.space(330))
    contentHeight: settingsPanel.fittedContentHeight(column.implicitHeight)
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
    // While dragging, show the live position but do not write: each write runs
    // mullion-set, which reloads Hyprland, and onMoved fires continuously. A
    // single drag would otherwise fire dozens of reloads.
    property real pending: NaN
    readonly property real stored: root.valueOf(settingKey, fallback)
    readonly property real current: isNaN(pending) ? stored : pending

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
      // Live feedback only.
      onMoved: parent.pending = Math.round(value)
      // One write, when the knob is let go.
      onReleased: {
        var settled = Math.round(value)
        parent.pending = NaN
        if (settled !== Math.round(parent.stored)) root.put(parent.settingKey, settled)
      }
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
