import QtQuick

// Throughput history over the last samples. Deliberately without axes or a
// legend: the numbers sit right below it, the curve only carries the shape.
Item {
  id: root

  property var points: []        // [{rx, tx}], newest last
  property int capacity: 60      // fixed scale so the curve scrolls in
  property real peak: 1
  property bool showRx: true
  property color rxColor: "white"
  property color txColor: "white"

  implicitHeight: 44

  onShowRxChanged: canvas.requestPaint()
  onPointsChanged: canvas.requestPaint()
  onPeakChanged: canvas.requestPaint()
  onWidthChanged: canvas.requestPaint()
  onHeightChanged: canvas.requestPaint()

  Canvas {
    id: canvas
    anchors.fill: parent
    antialiasing: true

    function plot(ctx, series, w, h, step, count) {
      var scale = Math.max(1, root.peak)
      for (var i = 0; i < count; i++) {
        // Right-aligned: the newest sample sticks to the right edge.
        var x = w - (count - 1 - i) * step
        var y = h - Math.min(1, series[i] / scale) * (h - 1) - 0.5
        i === 0 ? ctx.moveTo(x, y) : ctx.lineTo(x, y)
      }
    }

    onPaint: {
      var ctx = getContext("2d")
      var w = width, h = height
      ctx.reset()
      ctx.clearRect(0, 0, w, h)

      var pts = root.points || []
      var count = pts.length
      if (count < 2) return

      var step = w / Math.max(1, root.capacity - 1)
      var rx = [], tx = []
      for (var i = 0; i < count; i++) { rx.push(pts[i].rx); tx.push(pts[i].tx) }

      // Inbound as an area, outbound as a line on top — both stay readable
      // even where they overlap.
      if (!root.showRx) {
        // Nothing measured this direction — a flat line at zero would read as
        // "no traffic", which is a different claim.
        ctx.beginPath()
        plot(ctx, tx, w, h, step, count)
        ctx.strokeStyle = Qt.rgba(root.txColor.r, root.txColor.g, root.txColor.b, 0.9)
        ctx.lineWidth = 1.5
        ctx.stroke()
        return
      }

      ctx.beginPath()
      plot(ctx, rx, w, h, step, count)
      ctx.lineTo(w, h)
      ctx.lineTo(w - (count - 1) * step, h)
      ctx.closePath()
      ctx.fillStyle = Qt.rgba(root.rxColor.r, root.rxColor.g, root.rxColor.b, 0.22)
      ctx.fill()

      ctx.beginPath()
      plot(ctx, rx, w, h, step, count)
      ctx.strokeStyle = Qt.rgba(root.rxColor.r, root.rxColor.g, root.rxColor.b, 0.75)
      ctx.lineWidth = 1
      ctx.stroke()

      ctx.beginPath()
      plot(ctx, tx, w, h, step, count)
      ctx.strokeStyle = Qt.rgba(root.txColor.r, root.txColor.g, root.txColor.b, 0.9)
      ctx.lineWidth = 1.5
      ctx.stroke()
    }
  }
}
