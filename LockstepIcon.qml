import QtQuick
import QtQuick.Shapes
import qs.Commons

// The mark: two screens joined by one link — every monitor in step. When
// Lockstep is paused the link is cut, so the icon reads as "each screen on
// its own" at a glance. Vector paths, not a font glyph, so it stays crisp in
// the bar slot and follows the bar's foreground at any scale.
Item {
  id: root

  property real iconSize: Style.font.icon
  property color color: Color.foreground
  property bool active: true

  width: iconSize
  height: iconSize
  implicitWidth: iconSize
  implicitHeight: iconSize

  readonly property real stroke: Math.max(1, Math.round(iconSize * 0.1))

  function pt(x, y) {
    var s = root.iconSize - root.stroke
    var o = root.stroke / 2
    return (o + x * s).toFixed(2) + " " + (o + y * s).toFixed(2)
  }

  function rect(x0, y0, x1, y1) {
    return "M " + pt(x0, y0) + " L " + pt(x1, y0) + " L " + pt(x1, y1) + " L " + pt(x0, y1) + " Z"
  }

  // Two screens, each with its own stand.
  readonly property string screensPath: rect(0.00, 0.18, 0.40, 0.62) + " " + rect(0.60, 0.18, 1.00, 0.62)
    + " M " + pt(0.20, 0.62) + " L " + pt(0.20, 0.82)
    + " M " + pt(0.80, 0.62) + " L " + pt(0.80, 0.82)
    + " M " + pt(0.06, 0.82) + " L " + pt(0.34, 0.82)
    + " M " + pt(0.66, 0.82) + " L " + pt(0.94, 0.82)
  // The link between them: whole when active, cut when paused.
  readonly property string linkPath: active
    ? "M " + pt(0.40, 0.40) + " L " + pt(0.60, 0.40)
    : "M " + pt(0.40, 0.40) + " L " + pt(0.45, 0.40) + " M " + pt(0.55, 0.40) + " L " + pt(0.60, 0.40)
  // The same workspace on both screens: one dot each, filled when in step.
  readonly property string dotsPath: rect(0.14, 0.34, 0.26, 0.46) + " " + rect(0.74, 0.34, 0.86, 0.46)

  Shape {
    anchors.fill: parent
    preferredRendererType: Shape.CurveRenderer
    antialiasing: true

    ShapePath {
      strokeColor: root.color
      strokeWidth: root.stroke
      fillColor: "transparent"
      joinStyle: ShapePath.MiterJoin
      capStyle: ShapePath.FlatCap
      PathSvg { path: root.screensPath }
    }

    ShapePath {
      strokeColor: root.color
      strokeWidth: root.stroke
      fillColor: "transparent"
      capStyle: ShapePath.FlatCap
      PathSvg { path: root.linkPath }
    }

    ShapePath {
      strokeColor: "transparent"
      strokeWidth: 0
      fillColor: Qt.rgba(root.color.r, root.color.g, root.color.b, root.active ? 1.0 : 0.35)
      PathSvg { path: root.dotsPath }
      Behavior on fillColor { ColorAnimation { duration: 160; easing.type: Easing.OutQuad } }
    }
  }
}
