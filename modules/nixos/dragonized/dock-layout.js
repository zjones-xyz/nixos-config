var plasma = getApiVersion(1)

// Create left-edge panel (Dock) //

const dock = new Panel

// Basic Dock Geometry
dock.alignment = "center"
dock.height = Math.round(gridUnit * 3.8)
dock.hiding = "dodgewindows"
dock.lengthMode = "fit"
dock.location = "left"

// Fast-subset build (see hosts/pegasus/DECISIONS.md): luisbocanegra.panel.colorizer
// dropped — needs a compiled C++ backend, not just QML. This dock renders
// with the plain Dr460nized desktoptheme background, no extra blur layered
// on top yet.

// Icons-Only Task Manager
var tasks = dock.addWidget("org.kde.plasma.icontasks")
tasks.currentConfigGroup = ["General"]
tasks.writeConfig("fill", false)
tasks.writeConfig("iconSpacing", 2)
// Upstream also pins garuda-toolbox.desktop, snapper-tools.desktop, and
// octopi.desktop — Arch/Garuda-only tools with no NixOS equivalent, dropped
// rather than left dangling on unresolvable .desktop IDs.
//
// System Settings pinned as org.kde.systemsettings.desktop upstream (Arch's
// reverse-DNS Plasma 6 ID) — nixpkgs ships it as plain systemsettings.desktop
// instead, so icontasks couldn't resolve the pin (broken icon, clicking it
// threw a "System Notifications: Unknown application folder" toast).
// Confirmed via `ls /run/current-system/sw/share/applications | grep -i
// systemsettings` on pegasus (2026-07-11).
tasks.writeConfig("launchers", "applications:org.kde.konsole.desktop,preferred://browser,preferred://filemanager,applications:org.kde.plasma-systemmonitor.desktop,applications:systemsettings.desktop")
tasks.writeConfig("maxStripes", 1)
tasks.writeConfig("showOnlyCurrentDesktop", false)
tasks.writeConfig("showOnlyCurrentScreen", false)

// End of Dock creation //
