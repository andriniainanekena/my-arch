import Quickshell
import QtQuick

BarButton {
    iconSrc: Quickshell.env("HOME") + "/.local/share/ml4w-custom/menu.svg"
    colorize: false
    onClicked: {
        Quickshell.execDetached(["qs", "ipc", "call", "sidebar", "toggle"])
    }
}
