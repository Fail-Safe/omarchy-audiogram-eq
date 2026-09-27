import QtQuick
import qs.Commons

// Frequency-response view of the Audiogram EQ filter chain.
// Dual-mono: left and right paths when perEar is on.
Canvas {
  id: root

  property var bands: []
  property real preamp: 0
  property bool enabled: true
  property bool perEar: false
  property string fontFamily: Style.font.family
  property color foreground: Color.menu.text
  property color dim: Qt.darker(Color.menu.text, 1.55)
  property color accent: Color.accent
  property color leftColor: "#38bdf8"
  property color rightColor: "#f472b6"

  antialiasing: true
  opacity: enabled ? 1.0 : 0.4

  onBandsChanged: requestPaint()
  onPreampChanged: requestPaint()
  onEnabledChanged: requestPaint()
  onPerEarChanged: requestPaint()
  onWidthChanged: requestPaint()
  onHeightChanged: requestPaint()
  onVisibleChanged: if (visible) requestPaint()

  function bandColor(index) {
    return Qt.hsla((0.55 + index * 0.13) % 1.0, 0.65, 0.58, 1.0)
  }

  function shapeFor(type) {
    if (type === "low-shelf" || type === "lowshelf")
      return "lowshelf"
    if (type === "high-shelf" || type === "highshelf")
      return "highshelf"
    return "peaking"
  }

  function biquadDb(b0, b1, b2, a0, a1, a2, w) {
    var c1 = Math.cos(w), s1 = Math.sin(w), c2 = Math.cos(2 * w), s2 = Math.sin(2 * w)
    var numRe = b0 + b1 * c1 + b2 * c2, numIm = -(b1 * s1 + b2 * s2)
    var denRe = a0 + a1 * c1 + a2 * c2, denIm = -(a1 * s1 + a2 * s2)
    var magnitude = Math.sqrt((numRe * numRe + numIm * numIm) / Math.max(denRe * denRe + denIm * denIm, 1e-24))
    return 20 * Math.log10(Math.max(magnitude, 1e-12))
  }

  function sectionDb(shape, frequency, corner, q, gain, rate) {
    var w0 = 2 * Math.PI * corner / rate
    var alpha = Math.sin(w0) / (2 * Math.max(q, 0.05))
    var c = Math.cos(w0)
    var w = 2 * Math.PI * frequency / rate
    var A = Math.pow(10, gain / 40)
    var root2 = 2 * Math.sqrt(A) * alpha
    if (shape === "lowshelf")
      return biquadDb(
        A * ((A + 1) - (A - 1) * c + root2),
        2 * A * ((A - 1) - (A + 1) * c),
        A * ((A + 1) - (A - 1) * c - root2),
        (A + 1) + (A - 1) * c + root2,
        -2 * ((A - 1) + (A + 1) * c),
        (A + 1) + (A - 1) * c - root2,
        w
      )
    if (shape === "highshelf")
      return biquadDb(
        A * ((A + 1) + (A - 1) * c + root2),
        -2 * A * ((A - 1) + (A + 1) * c),
        A * ((A + 1) + (A - 1) * c - root2),
        (A + 1) - (A - 1) * c + root2,
        2 * ((A - 1) - (A + 1) * c),
        (A + 1) - (A - 1) * c - root2,
        w
      )
    return biquadDb(
      1 + alpha * A, -2 * c, 1 - alpha * A,
      1 + alpha / A, -2 * c, 1 - alpha / A,
      w
    )
  }

  function buildSections(gainKey) {
    var sections = []
    var pre = root.enabled ? Number(root.preamp) || 0 : 0
    sections.push({
      shape: "lowshelf",
      frequency: 20,
      q: 1.0,
      gain: pre,
      label: "P",
      node: false
    })
    var source = root.bands || []
    for (var i = 0; i < source.length; i++) {
      var band = source[i]
      var gain = root.enabled ? (Number(band[gainKey] !== undefined ? band[gainKey] : band.gain) || 0) : 0
      sections.push({
        shape: shapeFor(band.type),
        frequency: Number(band.frequency) || 1000,
        q: Number(band.q) || 1.0,
        gain: gain,
        label: String(i + 1),
        node: true
      })
    }
    return sections
  }

  function responseAt(sections, frequency, rate) {
    var sum = 0
    for (var s = 0; s < sections.length; s++) {
      var section = sections[s]
      sum += sectionDb(section.shape, frequency, section.frequency, section.q, section.gain, rate)
    }
    return sum
  }

  function strokeResponse(context, sections, frequencies, xFor, yFor, color, width) {
    var rate = 48000
    context.globalAlpha = 0.95
    context.strokeStyle = color
    context.lineWidth = width
    context.beginPath()
    for (var p = 0; p < frequencies.length; p++) {
      var y = yFor(responseAt(sections, frequencies[p], rate))
      if (p === 0)
        context.moveTo(xFor(frequencies[p]), y)
      else
        context.lineTo(xFor(frequencies[p]), y)
    }
    context.stroke()
  }

  function paintBandFills(context, sections, frequencies, xFor, yFor, colorForNode) {
    var rate = 48000
    var points = frequencies.length
    for (var s = 0; s < sections.length; s++) {
      var section = sections[s]
      if (!section.node)
        continue
      var curve = []
      for (var p = 0; p < points; p++)
        curve.push(sectionDb(section.shape, frequencies[p], section.frequency, section.q, section.gain, rate))
      var color = colorForNode(section, s)
      context.fillStyle = color
      context.strokeStyle = color
      context.globalAlpha = 0.12
      context.beginPath()
      context.moveTo(xFor(frequencies[0]), yFor(0))
      for (p = 0; p < points; p++)
        context.lineTo(xFor(frequencies[p]), yFor(curve[p]))
      context.lineTo(xFor(frequencies[points - 1]), yFor(0))
      context.closePath()
      context.fill()
    }
  }

  onPaint: {
    var context = getContext("2d")
    var width = root.width
    var height = root.height
    context.reset()
    context.clearRect(0, 0, width, height)
    if (width < 40 || height < 40)
      return

    var rate = 48000
    var padLeft = 30, padRight = 10, padTop = 10, padBottom = 18
    var plotWidth = width - padLeft - padRight
    var plotHeight = height - padTop - padBottom
    var minFrequency = 40, maxFrequency = 20000

    var leftSections = buildSections("leftGain")
    var rightSections = buildSections("rightGain")
    var midSections = buildSections("gain")

    var peak = Math.abs(Number(root.preamp) || 0)
    var source = root.bands || []
    for (var i = 0; i < source.length; i++) {
      peak = Math.max(peak, Math.abs(Number(source[i].leftGain) || 0))
      peak = Math.max(peak, Math.abs(Number(source[i].rightGain) || 0))
      peak = Math.max(peak, Math.abs(Number(source[i].gain) || 0))
    }
    var maxDb = Math.max(9, Math.ceil((peak + 1) / 3) * 3)
    var minDb = -Math.max(6, Math.ceil((Math.abs(Number(root.preamp) || 0) + 1) / 3) * 3)
    if (minDb > -6)
      minDb = -6

    function xFor(frequency) {
      var f = Math.max(minFrequency, Math.min(maxFrequency, frequency))
      return padLeft + (Math.log(f / minFrequency) / Math.log(maxFrequency / minFrequency)) * plotWidth
    }
    function yFor(value) {
      return padTop + ((maxDb - Math.max(minDb, Math.min(maxDb, value))) / (maxDb - minDb)) * plotHeight
    }

    var points = 160
    var frequencies = []
    for (var p = 0; p < points; p++)
      frequencies.push(minFrequency * Math.pow(maxFrequency / minFrequency, p / (points - 1)))

    // Grid
    context.lineWidth = 1
    context.font = "9px " + root.fontFamily
    context.fillStyle = root.dim
    context.strokeStyle = root.dim
    context.textBaseline = "middle"
    context.textAlign = "right"
    for (var tick = minDb; tick <= maxDb; tick += 3) {
      var y = yFor(tick)
      context.globalAlpha = tick === 0 ? 0.6 : 0.16
      context.beginPath()
      context.moveTo(padLeft, y)
      context.lineTo(width - padRight, y)
      context.stroke()
      if (tick % 6 === 0) {
        context.globalAlpha = 0.7
        context.fillText((tick > 0 ? "+" : "") + tick, padLeft - 4, y)
      }
    }

    // Prefer audiogram corners (4k/8k) over generic 5k/10k so band 8 is labeled.
    var frequencyTicks = [50, 100, 200, 500, 1000, 2000, 4000, 8000, 20000]
    var frequencyLabels = ["50", "100", "200", "500", "1k", "2k", "4k", "8k", "20k"]
    context.textAlign = "center"
    context.textBaseline = "top"
    for (var t = 0; t < frequencyTicks.length; t++) {
      var x = xFor(frequencyTicks[t])
      context.globalAlpha = 0.16
      context.beginPath()
      context.moveTo(x, padTop)
      context.lineTo(x, height - padBottom)
      context.stroke()
      context.globalAlpha = 0.7
      context.fillText(frequencyLabels[t], x, height - padBottom + 3)
    }

    if (root.perEar) {
      paintBandFills(context, leftSections, frequencies, xFor, yFor, function() { return root.leftColor })
      paintBandFills(context, rightSections, frequencies, xFor, yFor, function() { return root.rightColor })
      strokeResponse(context, leftSections, frequencies, xFor, yFor, root.leftColor, 2.0)
      strokeResponse(context, rightSections, frequencies, xFor, yFor, root.rightColor, 2.0)
    } else {
      paintBandFills(context, midSections, frequencies, xFor, yFor, function(section, index) {
        return bandColor(index)
      })
      strokeResponse(context, midSections, frequencies, xFor, yFor, root.foreground, 2.2)
    }

    // Preamp reference line
    var net = root.enabled ? (Number(root.preamp) || 0) : 0
    context.globalAlpha = 0.55
    context.strokeStyle = root.accent
    context.lineWidth = 1
    context.setLineDash([3, 3])
    context.beginPath()
    context.moveTo(padLeft, yFor(net))
    context.lineTo(width - padRight, yFor(net))
    context.stroke()
    context.setLineDash([])
    context.fillStyle = root.accent
    context.textAlign = "left"
    context.textBaseline = "bottom"
    context.globalAlpha = 0.8
    context.fillText("preamp " + (net > 0 ? "+" : "") + net.toFixed(1) + " dB", padLeft + 3, yFor(net) - 1)

    // Nodes
    var nodeSource = root.perEar ? leftSections : midSections
    for (var s = 0; s < nodeSource.length; s++) {
      var section = nodeSource[s]
      if (!section.node)
        continue
      var nx = xFor(section.frequency)
      if (root.perEar) {
        var leftGain = section.gain
        var rightGain = rightSections[s].gain
        context.globalAlpha = 1.0
        context.fillStyle = root.leftColor
        context.beginPath(); context.arc(nx - 5, yFor(leftGain), 5, 0, 2 * Math.PI); context.fill()
        context.fillStyle = root.rightColor
        context.beginPath(); context.arc(nx + 5, yFor(rightGain), 5, 0, 2 * Math.PI); context.fill()
      } else {
        var ny = yFor(section.gain)
        var fill = bandColor(s - 1)
        context.globalAlpha = 1.0
        context.fillStyle = fill
        context.beginPath(); context.arc(nx, ny, 7, 0, 2 * Math.PI); context.fill()
        context.strokeStyle = root.foreground
        context.lineWidth = 1.2
        context.beginPath(); context.arc(nx, ny, 7, 0, 2 * Math.PI); context.stroke()
        // Dark label on light fills — band hues get yellow/green past band 5.
        context.fillStyle = Qt.rgba(0.08, 0.09, 0.11, 1.0)
        context.font = "bold 9px " + root.fontFamily
        context.textAlign = "center"
        context.textBaseline = "middle"
        context.fillText(section.label, nx, ny)
      }
    }

    if (root.perEar) {
      context.globalAlpha = 0.85
      context.font = "9px " + root.fontFamily
      context.textAlign = "left"
      context.textBaseline = "top"
      context.fillStyle = root.leftColor
      context.fillText("L", padLeft + 4, padTop + 2)
      context.fillStyle = root.rightColor
      context.fillText("R", padLeft + 18, padTop + 2)
    }
    context.globalAlpha = 1.0
  }
}
