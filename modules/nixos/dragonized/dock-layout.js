var plasma = getApiVersion(1)

// Create bottom panel (Dock) //

const dock = new Panel

// Basic Dock Geometry
dock.alignment = "center"
dock.height = Math.round(gridUnit * 3.8)
dock.hiding = "dodgewindows"
dock.lengthMode = "fit"
dock.location = "bottom"

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
tasks.writeConfig("launchers", "applications:org.kde.konsole.desktop,preferred://browser,preferred://filemanager,applications:org.kde.plasma-systemmonitor.desktop,applications:org.kde.systemsettings.desktop")
tasks.writeConfig("maxStripes", 1)
tasks.writeConfig("showOnlyCurrentDesktop", false)
tasks.writeConfig("showOnlyCurrentScreen", false)

// End of Dock creation //
