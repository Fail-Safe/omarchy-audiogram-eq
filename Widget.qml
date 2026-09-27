import QtQuick
import qs.Ui
import qs.Commons

BarWidget {
  id: root

  moduleName: "failsafe.audiogram-eq"

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  readonly property bool opened:
    panelLoader.item ? panelLoader.item.opened === true : false
  readonly property bool popoutSwitchClosing:
    panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false

  function open() {
    if (panelLoader.item)
      panelLoader.item.open()
  }

  function close() {
    if (panelLoader.item)
      panelLoader.item.close()
  }

  function togglePanel() {
    if (panelLoader.item)
      panelLoader.item.toggle()
  }

  function closeForPopoutSwitch() {
    if (panelLoader.item)
      panelLoader.item.closeForPopoutSwitch()
  }

  function injectPanel() {
    var target = panelLoader.item
    if (!target)
      return
    if ("bar" in target)
      target.bar = root.bar
    if ("settings" in target)
      target.settings = root.settings
    if ("anchorItem" in target)
      target.anchorItem = button
    if ("hostWidget" in target)
      target.hostWidget = root
  }

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()

  Loader {
    id: panelLoader
    active: true
    visible: false
    source: Qt.resolvedUrl("Panel.qml")
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  // status (default) = fixed green/red ON/OFF. theme = Color.accent / Color.muted.
  // Read settings.iconColors directly so the binding re-evaluates on layout edits.
  readonly property string iconColors: {
    var raw = (settings && settings.iconColors !== undefined && settings.iconColors !== null)
      ? settings.iconColors
      : "status"
    return String(raw).toLowerCase() === "theme" ? "theme" : "status"
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar

    // FA deaf / hard-of-hearing — ear with slash (ON/OFF via icon color).
    text: "\uf2a4"
    slotSize: Style.bar.iconSlot

    tooltipText: panelLoader.item
      ? panelLoader.item.barTooltip
      : "Audiogram EQ"

    readonly property bool compensating:
      panelLoader.item ? panelLoader.item.compensationEnabled === true : false

    // Don't use bar.activeColor for ON — that token defaults to urgent/red.
    foreground: compensating
      ? (root.iconColors === "theme" ? Color.accent : "#22c55e")
      : (root.iconColors === "theme" ? Color.muted : Color.urgent)
    active: root.opened
    useActiveColor: false

    onPressed: function(mouseButton) {
      if (mouseButton === Qt.LeftButton)
        root.togglePanel()
      else if (mouseButton === Qt.MiddleButton && panelLoader.item)
        panelLoader.item.toggleEnabled()
    }
  }
}
