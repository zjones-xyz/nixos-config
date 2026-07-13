var plasma = getApiVersion(1)

// Create left-edge panel (Dock) //

const dock = new Panel

// Basic Dock Geometry
dock.alignment = "center"
dock.height = Math.round(gridUnit * 1.9) // half the original 3.8
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
// Pinned launchers replaced (2026-07-12) — every .desktop ID below was
// confirmed against the actual nixpkgs package source (not guessed), the
// same lesson learned from the System Settings bug: e.g. vivaldi's .deb
// keeps its original vivaldi-stable.desktop filename even though nixpkgs
// substitutes vivaldi-stable -> vivaldi inside the file's *contents*, and
// ferdium/discord/vscode/ticktick are each confirmed via their own
// makeDesktopItem/substituteInPlace calls in nixpkgs.
tasks.writeConfig("launchers", "applications:com.mitchellh.ghostty.desktop,applications:vivaldi-stable.desktop,applications:ferdium.desktop,applications:discord.desktop,applications:code.desktop,applications:ticktick.desktop,applications:org.kde.dolphin.desktop")
tasks.writeConfig("maxStripes", 1)
tasks.writeConfig("showOnlyCurrentDesktop", false)
tasks.writeConfig("showOnlyCurrentScreen", false)

// End of Dock creation //
