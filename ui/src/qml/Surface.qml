import QtQuick
import Logos.Theme

// A surface at one of three heights (exo-720.5), so what sits on what reads at a glance:
//   0  the page          backgroundTertiary — the sidebar, the details drawer
//   1  a card            surfaceRaised, a subtle border, radius 8
//   2  a popover, sheet  backgroundSecondary, a stronger border, radius 10
// `tone` tints a level-1 surface: "out" for what has left the room (U-2: the ground
// changes where the boundary is crossed), "needs" for a row that waits on you.
Rectangle {
    property int level: 1
    property string tone: ""

    radius: level === 0 ? 0 : level === 1 ? Theme.spacing.radiusLarge : 10
    color: tone === "out" ? Theme.palette.backgroundElevated
         : tone === "needs" ? MusterStyle.needsSoft
         : level === 0 ? Theme.palette.backgroundTertiary
         : level === 1 ? Theme.palette.surfaceRaised
         : Theme.palette.backgroundSecondary
    border.width: level === 0 ? 0 : 1
    border.color: tone === "out" ? MusterStyle.tint(MusterStyle.info, 0.45)
                : tone === "needs" ? MusterStyle.tint(MusterStyle.needs, 0.35)
                : level === 2 ? Theme.palette.border
                : Theme.palette.borderSubtle
}
