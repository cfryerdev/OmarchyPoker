import QtQuick
import qs.Commons
import qs.Ui

// Bar icon for the Hold'em table. Clicking runs the exact same IPC route a
// keybinding would use (omarchy-shell shell toggle …), mirroring how the
// first-party omarchy.menu bar widget summons its panel. Static icon only —
// nothing runs while the table is closed.
BarWidget {
  id: root
  moduleName: "cfryerdev.omarchyholdem"

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    // nf-md-cards_playing (U+F18A1): a pair of playing cards, so the table
    // does not wear the same spade mark as the project it forked from.
    text: "\uDB86\uDCA1"
    tooltipText: "Omarchy Hold'em"
    foreground: Color.accent
    fixedWidth: root.bar && root.bar.vertical ? -1 : Style.space(27)
    fixedHeight: root.bar && root.bar.vertical ? Style.space(26) : -1
    onPressed: function(b) {
      if (!root.bar) return
      root.bar.run("omarchy-shell shell toggle cfryerdev.omarchyholdem")
    }
  }
}
