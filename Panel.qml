import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import qs.Commons
import qs.Ui

// Lockstep in the bar: the mark, then one button per workspace group. Group
// g is the set of Hyprland workspaces { g, g + stride, g + 2 * stride, ... },
// one per monitor. The Lua side (hypr/lockstep.lua, loaded by Hyprland) keeps
// every monitor on the same group; this file shows the groups, lets you click
// between them, and opens a small menu with the active/paused state.
//
// The root id is `viewer` rather than `root`: kit types resolve inline
// Components in their own document, where `root` means something else.
Panel {
  id: viewer
  moduleName: "joachim.lockstep"
  ipcTarget: "lockstep"

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  readonly property int groups: Math.max(1, Math.min(10, Number(setting("groups", 10))))
  readonly property int stride: Math.max(groups, Number(setting("stride", 10)))
  readonly property int minShown: Math.max(1, Math.min(groups, Number(setting("minShown", 5))))

  // ------------------------------------------------------------ state
  //
  // The Lua side writes "1" or "0" to this file whenever the pause state
  // changes and once at load, so a missing file means Lockstep never loaded
  // into Hyprland (the dofile line is missing from bindings.lua).
  readonly property string stateFile: (Quickshell.env("XDG_STATE_HOME") || (Quickshell.env("HOME") + "/.local/state")) + "/omarchy/lockstep/enabled"
  property bool loaded: false
  property bool active: false
  property bool busy: false

  readonly property string statusText: !loaded ? "Not loaded" : (active ? "Active" : "Paused")
  readonly property string statusDetail: !loaded
    ? "Add the dofile line to ~/.config/hypr/bindings.lua and reload Hyprland."
    : (active ? "Every monitor follows the same workspace." : "Each monitor switches on its own, like stock Hyprland.")

  function refreshState() {
    stateView.reload()
    var text = String(stateView.text() || "").trim()
    loaded = text !== ""
    active = loaded && text.charAt(0) !== "0"
  }

  function setActive(on) {
    if (busy) return
    busy = true
    active = on
    toggleProcess.command = ["hyprctl", "repl", "lockstep.set_enabled(" + (on ? "true" : "false") + ")"]
    toggleProcess.running = true
  }

  // Quickshell pins workspace events to the focused monitor, so the other
  // monitors' activeWorkspace goes stale; re-query Hyprland when the menu opens.
  onOpenedChanged: if (opened) { Hyprland.refreshMonitors(); Hyprland.refreshWorkspaces() }

  FileView {
    id: stateView
    path: viewer.stateFile
    watchChanges: true
    printErrors: false
    onFileChanged: viewer.refreshState()
    onLoaded: viewer.refreshState()
    onLoadFailed: viewer.refreshState()
  }

  Process {
    id: toggleProcess
    onExited: function() {
      viewer.busy = false
      viewer.refreshState()
    }
  }

  // The state file is rewritten in place, but a missing file only appears
  // later; poll gently so "Not loaded" clears once Hyprland runs the Lua.
  Timer {
    interval: 5000
    running: !viewer.loaded
    repeat: true
    onTriggered: viewer.refreshState()
  }

  // ------------------------------------------------------------ groups

  function groupOf(id) {
    return ((id - 1) % viewer.stride) + 1
  }

  function isRegular(workspace) {
    return workspace !== null && workspace !== undefined && workspace.id > 0 && groupOf(workspace.id) <= viewer.groups
  }

  readonly property int focusedGroup: isRegular(Hyprland.focusedWorkspace) ? groupOf(Hyprland.focusedWorkspace.id) : 0

  // Groups with at least one window on any monitor, plus the focused one.
  function groupIds() {
    var ids = []
    for (var g = 1; g <= viewer.minShown; g++) ids.push(g)

    var values = Hyprland.workspaces.values
    for (var i = 0; i < values.length; i++) {
      var workspace = values[i]
      if (!isRegular(workspace)) continue
      if (workspace.toplevels.values.length === 0) continue
      var group = groupOf(workspace.id)
      if (ids.indexOf(group) === -1) ids.push(group)
    }

    if (viewer.focusedGroup > 0 && ids.indexOf(viewer.focusedGroup) === -1) ids.push(viewer.focusedGroup)

    ids.sort(function(left, right) { return left - right })
    return ids
  }

  function groupOccupied(g) {
    var values = Hyprland.workspaces.values
    for (var i = 0; i < values.length; i++) {
      var workspace = values[i]
      if (isRegular(workspace) && groupOf(workspace.id) === g && workspace.toplevels.values.length > 0) return true
    }
    return false
  }

  function focusGroup(g) {
    if (!viewer.bar) return
    viewer.bar.run("hyprctl dispatch " + Util.shellQuote("lockstep.dispatcher(" + g + ")"))
  }

  // Per-monitor view for the menu: name, index, and the workspace it shows.
  function monitorRows() {
    var rows = []
    var values = Hyprland.monitors.values
    for (var i = 0; i < values.length; i++) rows.push(values[i])
    rows.sort(function(a, b) { return a.x !== b.x ? a.x - b.x : a.y - b.y })
    var out = []
    for (var j = 0; j < rows.length; j++) {
      var mon = rows[j]
      var ws = mon.activeWorkspace
      out.push({
        name: mon.name,
        index: j,
        workspace: ws ? ws.id : 0,
        group: ws && isRegular(ws) ? groupOf(ws.id) : 0,
        focused: mon.focused
      })
    }
    return out
  }

  // ------------------------------------------------------------ bar

  readonly property real trailingGap: vertical ? 0 : Style.spaceReal(1.5)
  readonly property bool vertical: bar ? bar.vertical : false
  readonly property int barSize: bar ? bar.barSize : Style.bar.sizeHorizontal

  implicitWidth: vertical ? barSize : (button.width + grid.implicitWidth + trailingGap)
  implicitHeight: vertical ? (button.height + grid.implicitHeight) : barSize

  BarIconButton {
    id: button
    bar: viewer.bar
    anchors.left: parent.left
    anchors.top: parent.top
    tooltipText: "Lockstep: " + viewer.statusText

    iconComponent: Component {
      Item {
        LockstepIcon {
          anchors.centerIn: parent
          iconSize: Style.space(15)
          color: viewer.loaded && viewer.active ? viewer.barForeground : Qt.darker(viewer.barForeground, 1.55)
          active: viewer.loaded && viewer.active
        }
      }
    }

    onPressed: function(buttonCode) {
      if (buttonCode === Qt.MiddleButton && viewer.loaded) viewer.setActive(!viewer.active)
      else viewer.toggle()
    }
  }

  GridLayout {
    id: grid
    anchors.left: viewer.vertical ? parent.left : button.right
    anchors.top: viewer.vertical ? button.bottom : parent.top
    anchors.right: viewer.vertical ? parent.right : undefined
    anchors.bottom: viewer.vertical ? undefined : parent.bottom
    anchors.rightMargin: viewer.vertical ? 0 : viewer.trailingGap
    columns: viewer.vertical ? 1 : viewer.groupIds().length
    columnSpacing: viewer.vertical ? 0 : Style.space(1)
    rowSpacing: viewer.vertical ? Style.space(2) : 0
    opacity: viewer.loaded && !viewer.active ? 0.6 : 1

    Repeater {
      model: viewer.groupIds()

      WidgetButton {
        required property int modelData

        readonly property bool occupied: viewer.groupOccupied(modelData)
        readonly property bool focused: viewer.focusedGroup === modelData

        bar: viewer.bar
        text: focused ? "󱓻" : (modelData === 10 ? "0" : String(modelData))
        opacity: occupied || focused ? 1 : 0.5
        horizontalMargin: 6
        verticalPadding: 6
        fixedWidth: viewer.vertical ? viewer.barSize : Style.space(20)
        fixedHeight: viewer.barSize
        tooltipText: "Workspace " + modelData + (viewer.active ? " on every monitor" : "")
        onPressed: function() { viewer.focusGroup(modelData) }
      }
    }
  }

  // ------------------------------------------------------------ menu

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: viewer
    bar: viewer.bar
    open: viewer.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(300))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(420))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent

      onActivateRequested: if (viewer.loaded) viewer.setActive(!viewer.active)
      onCloseRequested: viewer.close()
      onTabRequested: function(direction) { viewer.switchPanel(direction) }
      onTextKey: function(t) {
        var key = String(t).toLowerCase()
        if (key === " " && viewer.loaded) viewer.setActive(!viewer.active)
      }

      Column {
        id: column
        width: parent.width
        spacing: Style.space(12)

        PanelHero {
          id: hero
          width: parent.width
          title: "Lockstep"
          meta: viewer.statusText + (viewer.loaded && viewer.active && viewer.focusedGroup > 0 ? "  ·  workspace " + viewer.focusedGroup : "")
          foreground: viewer.foreground
          fontFamily: viewer.fontFamily

          iconComponent: Component {
            LockstepIcon {
              iconSize: Style.font.display
              color: viewer.foreground
              active: viewer.loaded && viewer.active
            }
          }

          trailingControl: Component {
            ToggleSwitch {
              id: powerSwitch
              visible: viewer.loaded
              checked: viewer.active
              busy: viewer.busy
              foreground: hero.foreground
              onToggled: viewer.setActive(!viewer.active)

              PanelToolTip {
                visible: powerSwitch.containsMouse
                text: viewer.active ? "Pause: let each monitor switch on its own" : "Resume: keep every monitor in step"
                fontFamily: hero.fontFamily
              }
            }
          }
        }

        Text {
          width: parent.width
          text: viewer.statusDetail
          color: viewer.loaded ? viewer.dim : viewer.urgent
          font.family: viewer.fontFamily
          font.pixelSize: Style.font.bodySmall
          wrapMode: Text.WordWrap
        }

        PanelSectionHeader {
          text: "MONITORS"
          foreground: viewer.foreground
          fontFamily: viewer.fontFamily
        }

        Column {
          width: parent.width
          spacing: Style.space(4)

          Repeater {
            model: viewer.monitorRows()

            RowLayout {
              required property var modelData
              width: parent.width
              spacing: Style.space(8)

              Text {
                text: modelData.focused ? "󱓻" : "󰝦"
                color: modelData.focused ? viewer.foreground : viewer.dim
                font.family: viewer.fontFamily
                font.pixelSize: Style.font.bodySmall
              }

              Text {
                Layout.fillWidth: true
                text: modelData.name
                color: viewer.foreground
                font.family: viewer.fontFamily
                font.pixelSize: Style.font.body
                elide: Text.ElideRight
              }

              Text {
                text: modelData.group > 0
                  ? ("workspace " + modelData.group + "  ·  id " + modelData.workspace)
                  : ("id " + modelData.workspace)
                color: viewer.dim
                font.family: viewer.fontFamily
                font.pixelSize: Style.font.bodySmall
              }
            }
          }
        }

        Text {
          width: parent.width
          text: "Middle-click the bar icon to pause or resume. Space toggles here."
          color: viewer.dim
          font.family: viewer.fontFamily
          font.pixelSize: Style.font.bodySmall
          wrapMode: Text.WordWrap
        }
      }
    }
  }
}
