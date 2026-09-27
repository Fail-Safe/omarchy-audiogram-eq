import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell.Io
import qs.Ui
import qs.Commons
import "components"

Panel {
  id: root

  moduleName: "failsafe.audiogram-eq"
  ipcTarget: "failsafe.audiogram-eq"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  property string errorMessage: ""
  property var pendingCommands: []
  property bool popoutSwitchClosing: false
  // Mirrored for the bar icon so ON/OFF color updates reliably.
  property bool compensationEnabled: false
  property bool profileDirty: false
  property bool profileEditing: false
  property bool audiogramExpanded: true
  property bool audiogramUserToggled: false
  property bool collapseAudiogramAfterSave: false
  property string draftLabel: ""
  property var draftThresholds: []
  property string profileId: "custom"

  property string backendPath: {
    var raw = Qt.resolvedUrl("backend/agc").toString().replace(/^file:\/\//, "")
    try { return decodeURIComponent(raw) } catch (e) { return raw }
  }

  property var state: ({
    ready: false,
    enabled: false,
    mode: "auto",
    activePreset: "speakers",
    intensity: 50,
    intensityByPreset: ({ headphones: 100, speakers: 50 }),
    perEar: false,
    perEarByPreset: ({ headphones: true, speakers: false }),
    profileId: "custom",
    profileLabel: "My audiogram",
    thresholds: [],
    deviceName: "Detecting…",
    disclaimer: "Assistive desktop EQ. Not a hearing aid or medical device.",
    bands: [],
    preamp: 0,
    graphPresent: false
  })

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  readonly property string barTooltip: state.ready
    ? ("Audiogram EQ · " + (state.enabled ? "ON" : "OFF")
       + " · " + state.activePreset
       + (state.perEar ? " · L/R" : "")
       + " · " + state.deviceName)
    : "Audiogram EQ"

  readonly property bool mutationBusy: mutationProcess.running || pendingCommands.length > 0

  function open(payload) {
    refresh()
    root.controller.show()
  }

  function close() {
    root.controller.hide()
  }

  function closeForPopoutSwitch() {
    popoutSwitchClosing = true
    close()
    Qt.callLater(function() { popoutSwitchClosing = false })
  }

  function toggle() {
    root.opened ? root.close() : root.open({})
  }

  function switchPanel(direction) {
    if (root.hostWidget && root.hostWidget.bar && typeof root.hostWidget.bar.switchPanelFrom === "function")
      return root.hostWidget.bar.switchPanelFrom(root.hostWidget, direction)
    return false
  }

  function showError(message) {
    errorMessage = String(message || "Audiogram EQ command failed")
  }

  function copyThresholds(source) {
    var rows = []
    var list = source || []
    for (var i = 0; i < list.length; i++) {
      var row = list[i]
      rows.push({
        frequency: Number(row.frequency) || 0,
        left: Math.round(Number(row.left) || 0),
        right: Math.round(Number(row.right) || 0)
      })
    }
    return rows
  }

  function hasConfiguredThresholds(rows) {
    var list = rows || []
    for (var i = 0; i < list.length; i++) {
      if ((Number(list[i].left) || 0) > 0 || (Number(list[i].right) || 0) > 0)
        return true
    }
    return false
  }

  function audiogramSummary() {
    if (!root.draftThresholds || root.draftThresholds.length === 0)
      return "No thresholds yet"
    var left = []
    var right = []
    for (var i = 0; i < root.draftThresholds.length; i++) {
      left.push(Number(root.draftThresholds[i].left) || 0)
      right.push(Number(root.draftThresholds[i].right) || 0)
    }
    function avg(vals) {
      if (!vals.length) return 0
      var sum = 0
      for (var i = 0; i < vals.length; i++) sum += vals[i]
      return Math.round(sum / vals.length)
    }
    return root.draftLabel + " · L≈" + avg(left) + " / R≈" + avg(right) + " dB HL"
  }

  function toggleAudiogramEditor() {
    root.audiogramUserToggled = true
    root.audiogramExpanded = !root.audiogramExpanded
  }

  function syncDraftFrom(next) {
    if (root.profileDirty)
      return
    root.profileId = String(next.profileId || "custom")
    root.draftLabel = String(next.profileLabel || next.profileId || "My audiogram")
    root.draftThresholds = copyThresholds(next.thresholds)
    if (labelField && !labelField.activeFocus)
      labelField.text = root.draftLabel
    if (!root.audiogramUserToggled)
      root.audiogramExpanded = !root.hasConfiguredThresholds(root.draftThresholds)
  }

  function copyState(next) {
    var bands = []
    if (next.bands && next.bands.length) {
      for (var i = 0; i < next.bands.length; i++) {
        var b = next.bands[i]
        var gain = Number(b.gain) || 0
        var leftGain = b.leftGain == null ? gain : Number(b.leftGain)
        var rightGain = b.rightGain == null ? gain : Number(b.rightGain)
        bands.push({
          frequency: Number(b.frequency) || 0,
          gain: gain,
          leftGain: leftGain,
          rightGain: rightGain,
          type: String(b.type || "peaking"),
          q: Number(b.q) || 1.0,
          thresholdDbHl: b.thresholdDbHl == null ? null : Number(b.thresholdDbHl)
        })
      }
    }
    return {
      ready: next.ready === true || !!next.bands,
      enabled: next.enabled === true,
      mode: String(next.mode || "auto"),
      activePreset: String(next.activePreset || "speakers"),
      intensity: Number(next.intensity),
      intensityByPreset: {
        headphones: Number((next.intensityByPreset || {}).headphones),
        speakers: Number((next.intensityByPreset || {}).speakers)
      },
      perEar: next.perEar === true,
      perEarByPreset: {
        headphones: (next.perEarByPreset || {}).headphones !== false,
        speakers: (next.perEarByPreset || {}).speakers === true
      },
      profileId: String(next.profileId || "custom"),
      profileLabel: String(next.profileLabel || next.profileId || "My audiogram"),
      thresholds: copyThresholds(next.thresholds),
      deviceName: String(next.deviceName || "No audio output"),
      disclaimer: String(next.disclaimer || "Assistive desktop EQ. Not a hearing aid or medical device."),
      bands: bands,
      preamp: Number((next.preamp || {}).value) || 0,
      graphPresent: next.graphPresent === true
    }
  }

  function applyStatus(next, clearError) {
    if (!next || next.error) {
      if (next && next.error)
        showError(next.error)
      return
    }
    state = copyState(next)
    compensationEnabled = state.enabled === true
    syncDraftFrom(next)
    if (clearError)
      errorMessage = ""
    Qt.callLater(function() {
      if (eqCurve)
        eqCurve.requestPaint()
    })
  }

  function parseResult(text, isMutation) {
    var raw = String(text || "").trim()
    if (!raw) {
      if (isMutation)
        showError("Backend returned no result")
      return
    }
    try {
      var result = JSON.parse(raw)
      if (result.error) {
        showError(result.error)
        // Keep the red error visible; do not immediately overwrite with status.
        return
      }
      if (isMutation === true) {
        root.profileDirty = false
        if (root.collapseAudiogramAfterSave) {
          root.audiogramExpanded = false
          root.audiogramUserToggled = false
          root.collapseAudiogramAfterSave = false
        }
      }
      // Status polls should not wipe a sticky error; mutations that succeed do.
      applyStatus(result, isMutation === true)
    } catch (e) {
      showError("Invalid response from agc")
    }
  }

  function refresh() {
    if (!statusProcess.running)
      statusProcess.running = true
  }

  function enqueue(args) {
    var queue = pendingCommands.slice()
    queue.push(args)
    pendingCommands = queue
    runNextMutation()
  }

  function runNextMutation() {
    if (mutationProcess.running || pendingCommands.length === 0)
      return
    var queue = pendingCommands.slice()
    var args = queue.shift()
    pendingCommands = queue
    mutationProcess.command = [backendPath, "--json"].concat(args)
    mutationProcess.running = true
  }

  function toggleEnabled() {
    enqueue([state.enabled ? "disable" : "enable"])
  }

  function setMode(mode) {
    enqueue(["mode", mode])
  }

  function setIntensity(value) {
    enqueue(["intensity", String(Math.round(value))])
  }

  function togglePerEar() {
    enqueue(["per-ear", "toggle"])
  }

  function markProfileDirty() {
    root.profileDirty = true
  }

  function setDraftThreshold(index, ear, value) {
    var rows = []
    for (var i = 0; i < root.draftThresholds.length; i++) {
      var row = root.draftThresholds[i]
      rows.push({
        frequency: row.frequency,
        left: row.left,
        right: row.right
      })
    }
    if (index < 0 || index >= rows.length)
      return
    rows[index][ear] = Math.round(Number(value) || 0)
    root.draftThresholds = rows
    root.markProfileDirty()
  }

  function saveProfile() {
    var left = {}
    var right = {}
    for (var i = 0; i < root.draftThresholds.length; i++) {
      var row = root.draftThresholds[i]
      var key = String(row.frequency)
      left[key] = Math.round(Number(row.left) || 0)
      right[key] = Math.round(Number(row.right) || 0)
    }
    var payload = JSON.stringify({
      id: root.profileId || root.state.profileId || "custom",
      label: root.draftLabel,
      left: left,
      right: right
    })
    enqueue(["profile-save", payload])
    root.collapseAudiogramAfterSave = true
  }

  function revertProfile() {
    root.profileDirty = false
    syncDraftFrom(root.state)
  }

  function formatHz(hz) {
    if (hz >= 1000)
      return (hz / 1000) + "k"
    return String(hz)
  }

  function formatGain(value) {
    var n = Number(value) || 0
    return (n >= 0 ? "+" : "") + n.toFixed(1)
  }

  Process {
    id: statusProcess
    command: [root.backendPath, "--json", "status"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.parseResult(text, false)
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        if (text && text.trim())
          root.showError(text.trim())
      }
    }
  }

  Process {
    id: mutationProcess
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.parseResult(text, true)
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        if (text && text.trim())
          root.showError(text.trim())
      }
    }
    onExited: root.runNextMutation()
  }

  Timer {
    id: refreshTimer
    interval: 800
    onTriggered: root.refresh()
  }

  Timer {
    interval: 4000
    running: root.opened
    repeat: true
    onTriggered: root.refresh()
  }

  Component.onCompleted: refresh()

  KeyboardPanel {
    id: popup
    anchorItem: root.anchorItem
    owner: root.hostWidget || root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    centerOnBar: false
    contentWidth: popup.fittedContentWidth(Style.space(420), Style.space(520))
    // Cap to the screen; tall content scrolls inside the card.
    contentHeight: popup.fittedContentHeight(panelColumn.implicitHeight, Style.space(760))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: root.profileEditing
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(text) {
        if (root.profileEditing)
          return
        var k = String(text).toLowerCase()
        if (k === " ") root.toggleEnabled()
        else if (k === "a") root.setMode("auto")
        else if (k === "h") root.setMode("headphones")
        else if (k === "s") root.setMode("speakers")
        else if (k === "e") root.togglePerEar()
        else if (k === "r") root.refresh()
      }

      Flickable {
        id: scroller
        anchors.fill: parent
        contentWidth: width
        contentHeight: panelColumn.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height + 1 && !root.profileEditing
        flickableDirection: Flickable.VerticalFlick

        Column {
          id: panelColumn
          // Hair inset so clipped row borders don't read as unfinished.
          x: Style.space(2)
          width: parent.width - Style.space(4)
          spacing: Style.spacing.md

        Item {
          width: parent.width
          implicitHeight: Math.max(headerIcon.implicitHeight, headerCopy.implicitHeight, onOffButton.implicitHeight)

          Text {
            id: headerIcon
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            // FA assistive-listening-systems — needs the Nerd Font face, not a fallback sans.
            text: "\uf2a2"
            color: Color.menu.text
            font.family: (root.bar && root.bar.fontFamily) ? root.bar.fontFamily : "JetBrainsMono Nerd Font"
            font.pixelSize: Style.font.display
          }

          Column {
            id: headerCopy
            anchors.left: headerIcon.right
            anchors.leftMargin: Style.spacing.sm
            anchors.right: onOffButton.left
            anchors.rightMargin: Style.spacing.md
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.spacing.xxs

            Text {
              text: "Audiogram EQ"
              color: Color.menu.text
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
              font.bold: true
            }

            Text {
              width: parent.width
              text: root.state.profileLabel + " · " + root.state.deviceName
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              elide: Text.ElideRight
            }
          }

          Button {
            id: onOffButton
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            text: root.state.enabled ? "ON" : "OFF"
            selected: root.state.enabled
            focusable: true
            enabled: !root.mutationBusy
            onClicked: root.toggleEnabled()
          }
        }

        Text {
          width: parent.width
          visible: root.errorMessage !== ""
          text: root.errorMessage
          color: Color.urgent
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }

        Column {
          width: parent.width
          spacing: Style.spacing.xs

          Item {
            width: parent.width
            height: Math.max(audiogramHeaderLabel.implicitHeight, audiogramToggle.implicitHeight)

            Text {
              id: audiogramHeaderLabel
              anchors.left: parent.left
              anchors.right: audiogramToggle.left
              anchors.rightMargin: Style.spacing.sm
              anchors.verticalCenter: parent.verticalCenter
              text: "AUDIOGRAM (dB HL)"
              color: Color.menu.text
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
            }

            Button {
              id: audiogramToggle
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              text: root.audiogramExpanded ? "Hide" : "Edit"
              focusable: true
              onClicked: root.toggleAudiogramEditor()
            }
          }

          Text {
            width: parent.width
            visible: !root.audiogramExpanded
            text: root.audiogramSummary()
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }

          Text {
            width: parent.width
            visible: root.audiogramExpanded
            text: "Enter left/right thresholds from your clinic chart (250–8k, including 3k/6k when listed). Saved to your config — not into the plugin."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }

          TextField {
            id: labelField
            width: parent.width
            visible: root.audiogramExpanded
            placeholderText: "Profile label"
            foreground: Color.menu.text
            accent: Color.accent
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            verticalPadding: Style.space(4)
            onTextEdited: {
              root.draftLabel = text
              root.markProfileDirty()
            }
            onActiveFocusChanged: root.profileEditing = activeFocus || leftFocusProxy.focused || rightFocusProxy.focused
          }

          // Focus proxies updated by threshold NumberFields below.
          QtObject {
            id: leftFocusProxy
            property bool focused: false
          }
          QtObject {
            id: rightFocusProxy
            property bool focused: false
          }

          Item {
            width: parent.width
            height: Style.space(18)
            visible: root.audiogramExpanded

            Text {
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              width: Style.space(36)
              text: "Hz"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }

            Text {
              anchors.left: parent.left
              anchors.leftMargin: Style.space(52)
              anchors.verticalCenter: parent.verticalCenter
              width: Style.space(88)
              horizontalAlignment: Text.AlignHCenter
              text: "L"
              color: "#38bdf8"
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
            }

            Text {
              anchors.left: parent.left
              anchors.leftMargin: Style.space(148)
              anchors.verticalCenter: parent.verticalCenter
              width: Style.space(88)
              horizontalAlignment: Text.AlignHCenter
              text: "R"
              color: "#f472b6"
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
            }
          }

          Repeater {
            model: root.audiogramExpanded ? root.draftThresholds : []

            Item {
              required property var modelData
              required property int index
              width: panelColumn.width
              height: Style.space(34)

              Text {
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                width: Style.space(36)
                text: root.formatHz(modelData.frequency)
                color: Color.menu.text
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }

              NumberField {
                id: leftField
                anchors.left: parent.left
                anchors.leftMargin: Style.space(52)
                anchors.verticalCenter: parent.verticalCenter
                label: ""
                from: 0
                to: 120
                stepSize: 5
                value: modelData.left
                fieldWidth: Style.space(88)
                foreground: Color.menu.text
                accent: "#38bdf8"
                fontFamily: root.fontFamily
                fontSize: Style.font.caption
                spacing: 0
                onModified: function(v) { root.setDraftThreshold(index, "left", v) }

                Connections {
                  target: leftField.field
                  function onActiveFocusChanged() {
                    leftFocusProxy.focused = leftField.field.activeFocus
                    root.profileEditing = labelField.activeFocus || leftFocusProxy.focused || rightFocusProxy.focused
                  }
                }
              }

              NumberField {
                id: rightField
                anchors.left: parent.left
                anchors.leftMargin: Style.space(148)
                anchors.verticalCenter: parent.verticalCenter
                label: ""
                from: 0
                to: 120
                stepSize: 5
                value: modelData.right
                fieldWidth: Style.space(88)
                foreground: Color.menu.text
                accent: "#f472b6"
                fontFamily: root.fontFamily
                fontSize: Style.font.caption
                spacing: 0
                onModified: function(v) { root.setDraftThreshold(index, "right", v) }

                Connections {
                  target: rightField.field
                  function onActiveFocusChanged() {
                    rightFocusProxy.focused = rightField.field.activeFocus
                    root.profileEditing = labelField.activeFocus || leftFocusProxy.focused || rightFocusProxy.focused
                  }
                }
              }
            }
          }

          Row {
            spacing: Style.spacing.sm
            visible: root.audiogramExpanded

            Button {
              text: "Save audiogram"
              selected: root.profileDirty
              focusable: true
              enabled: !root.mutationBusy && root.profileDirty
              onClicked: root.saveProfile()
            }

            Button {
              text: "Revert"
              focusable: true
              enabled: !root.mutationBusy && root.profileDirty
              onClicked: root.revertProfile()
            }
          }
        }

        Row {
          spacing: Style.spacing.sm

          Repeater {
            model: [
              { id: "auto", label: "Auto" },
              { id: "headphones", label: "Headphones" },
              { id: "speakers", label: "Speakers" }
            ]

            Button {
              required property var modelData
              text: modelData.label
              selected: root.state.mode === modelData.id
              focusable: true
              enabled: !root.mutationBusy
              onClicked: root.setMode(modelData.id)
            }
          }
        }

        Column {
          width: parent.width
          spacing: Style.spacing.xs

          Text {
            text: (root.state.activePreset === "headphones" ? "Headphones" : "Speakers")
              + " intensity " + root.state.intensity + "%"
            color: Color.menu.text
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          Text {
            text: "Saved per mode · headphones "
              + Number((root.state.intensityByPreset || {}).headphones) + "% / speakers "
              + Number((root.state.intensityByPreset || {}).speakers) + "%"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          Slider {
            id: intensitySlider
            width: parent.width
            from: 0
            to: 100
            stepSize: 5
            value: root.state.intensity
            enabled: !root.mutationBusy
            onPressedChanged: {
              if (!pressed)
                root.setIntensity(value)
            }
          }
        }

        Item {
          width: parent.width
          implicitHeight: Math.max(perEarCopy.implicitHeight, perEarButton.implicitHeight)

          Column {
            id: perEarCopy
            anchors.left: parent.left
            anchors.right: perEarButton.left
            anchors.rightMargin: Style.spacing.md
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.spacing.xxs

            Text {
              text: "Per-ear L/R"
              color: Color.menu.text
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
            }

            Text {
              width: parent.width
              text: "Independent left/right gains · default on for headphones, off for speakers"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }
          }

          Button {
            id: perEarButton
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            text: root.state.perEar ? "ON" : "OFF"
            selected: root.state.perEar
            focusable: true
            enabled: !root.mutationBusy
            onClicked: root.togglePerEar()
          }
        }

        Text {
          text: "Prescribed gains (preamp " + root.state.preamp + " dB) · " + root.state.activePreset
            + (root.state.perEar ? " · L/R" : " · averaged")
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }

        Text {
          text: "RESPONSE CURVE"
          color: Color.menu.text
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          font.bold: true
        }

        EqCurve {
          id: eqCurve
          width: parent.width
          height: Style.space(160)
          bands: root.state.bands
          preamp: root.state.preamp
          enabled: root.state.enabled
          perEar: root.state.perEar
          fontFamily: root.fontFamily
          foreground: Color.menu.text
          dim: root.dim
          accent: Color.accent
        }

        Text {
          width: parent.width
          text: root.state.perEar
            ? "Cyan = left, pink = right. Nodes mark each ear’s gain at that band. The dashed line is the shared preamp."
            : "Each coloured band is one filter; numbered nodes mark frequency and gain. The bright line is everything added together. The dashed line is the preamp."
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }

        Repeater {
          model: root.state.bands

          Item {
            required property var modelData
            width: panelColumn.width
            height: root.state.perEar ? Style.space(34) : Style.space(22)

            Text {
              id: freqLabel
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              width: Style.space(36)
              text: root.formatHz(modelData.frequency)
              color: Color.menu.text
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }

            Column {
              anchors.left: freqLabel.right
              anchors.leftMargin: Style.spacing.sm
              anchors.right: gainLabel.left
              anchors.rightMargin: Style.spacing.sm
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.spacing.xxs

              Row {
                width: parent.width
                spacing: Style.spacing.xs
                visible: root.state.perEar

                Text {
                  width: Style.space(12)
                  text: "L"
                  color: "#38bdf8"
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }

                Rectangle {
                  width: parent.width - Style.space(16)
                  height: Style.space(6)
                  radius: Style.space(3)
                  color: Qt.rgba(0.22, 0.74, 0.97, 0.15)

                  Rectangle {
                    width: parent.width * Math.min(1, Math.max(0, (modelData.leftGain || 0) / 12))
                    height: parent.height
                    radius: parent.radius
                    color: "#38bdf8"
                  }
                }
              }

              Row {
                width: parent.width
                spacing: Style.spacing.xs
                visible: root.state.perEar

                Text {
                  width: Style.space(12)
                  text: "R"
                  color: "#f472b6"
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }

                Rectangle {
                  width: parent.width - Style.space(16)
                  height: Style.space(6)
                  radius: Style.space(3)
                  color: Qt.rgba(0.96, 0.45, 0.71, 0.15)

                  Rectangle {
                    width: parent.width * Math.min(1, Math.max(0, (modelData.rightGain || 0) / 12))
                    height: parent.height
                    radius: parent.radius
                    color: "#f472b6"
                  }
                }
              }

              Rectangle {
                width: parent.width
                height: Style.space(8)
                radius: Style.space(4)
                visible: !root.state.perEar
                color: Qt.rgba(Color.menu.text.r, Color.menu.text.g, Color.menu.text.b, 0.12)

                Rectangle {
                  width: parent.width * Math.min(1, Math.max(0, (modelData.gain || 0) / 12))
                  height: parent.height
                  radius: parent.radius
                  color: Color.menu.text
                }
              }
            }

            Text {
              id: gainLabel
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              width: Style.space(88)
              horizontalAlignment: Text.AlignRight
              text: root.state.perEar
                ? (root.formatGain(modelData.leftGain) + " / " + root.formatGain(modelData.rightGain))
                : (root.formatGain(modelData.gain) + " dB")
              color: Color.menu.text
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
          }
        }

        Text {
          width: parent.width
          text: root.state.disclaimer
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }

        // Keep the last wrapped line clear of the card’s bottom clip edge.
        Item { width: 1; height: Style.spacing.md }
      }
      }
    }
  }
}
