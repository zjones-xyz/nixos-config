var plasma = getApiVersion(1)

// Center Krunner on screen - requires relogin
const krunner = ConfigFile('krunnerrc')
krunner.group = 'General'
krunner.writeEntry('FreeFloating', true);

// Change keyboard repeat delay from default 600ms to 250ms
const kbd = ConfigFile('kcminputrc')
kbd.group = 'Keyboard'
kbd.writeEntry('RepeatDelay', 250);

// Create Top Panel
const panel = new Panel
panel.alignment = "left"
panel.floating = false
panel.height = Math.round(gridUnit * 1.8);
panel.location = "top"


// The order in which the below Applets are listed will be reflected from Left to Right in the Top Panel. //
//
// Fast-subset build (see hosts/pegasus/DECISIONS.md): org.kde.windowbuttons
// and luisbocanegra.panel.colorizer are deferred (both need a compiled C++
// backend, not just QML) — dropped from this layout rather than referencing
// unpackaged plasmoid IDs. Window control buttons come from KWin's own
// per-window titlebar (Sweet-Dark aurorae decoration) instead of a panel
// widget. Panels render with the plain Dr460nized desktoptheme background —
// no extra blur/transparency layered on top yet.

// The Kickoff launcher
var launcher = panel.addWidget("org.kde.plasma.kickoff")
launcher.currentConfigGroup = ["General"]
launcher.writeConfig("icon", "distributor-logo-garuda")
launcher.writeConfig("lengthFirstMargin", 7)
launcher.currentConfigGroup = ["Shortcuts"]
launcher.writeConfig("global", "Alt+F1")

// Window Title - Using a fork for Plasma 6 (plasma6-applets-window-title)
var title = panel.addWidget("org.kde.windowtitle")
title.currentConfigGroup = ["General"]
title.writeConfig("filterActivityInfo", false)
title.writeConfig("lengthFirstMargin", 7)
title.writeConfig("lengthMarginsLock", false)
title.writeConfig("filterByScreen", true)
title.currentConfigGroup = ["Appearance"]
title.writeConfig("altTxt", "Dr460nized KDE 🔥")
title.writeConfig("isBold", true)
title.writeConfig("visible", false)

// Window Global Menu
var plasmaappmenu = panel.addWidget("org.kde.plasma.appmenu")

// Add Left Expandable Spacer — the only spacer in this panel, so it eats
// all the slack and pushes everything after it (tray, clock, switcher)
// flush to the panel's far right edge.
var spacer = panel.addWidget("org.kde.plasma.panelspacer")

// System Tray
var systray = panel.addWidget("org.kde.plasma.systemtray")
systray.currentConfigGroup = ["General"]
// In Plasma 6, 'scaleIconsToFit' is the boolean that toggles
// between "Small" (false) and "Scale with Panel height" (true)
systray.writeConfig("scaleIconsToFit", true)
systray.writeConfig("iconSize", 0) // Optional: If you want to ensure it doesn't default to a tiny fixed size

// Digital Clock — placed after the tray so it sits to the tray's right.
var digitalclock = panel.addWidget("org.kde.plasma.digitalclock")
digitalclock.currentConfigGroup = ["Appearance"]
digitalclock.writeConfig("autoFontAndSize", false)
digitalclock.writeConfig("customDateFormat", "MMM d,")
digitalclock.writeConfig("dateDisplayFormat", "BesideTime")
digitalclock.writeConfig("dateFormat", "custom")
digitalclock.writeConfig("enabledCalendarPlugins", "alternatecalendar,astronomicalevents,holidaysevents")
// use24hFormat is an index into the KCM's combobox model [12-Hour, Use
// region defaults, 24-Hour] (confirmed via applets/digital-clock/
// configAppearance.qml in plasma-workspace's own source, since main.xml's
// <default>1</default> only tells you the *default* index, not what the
// values mean) — 2 forces 24-hour regardless of locale.
digitalclock.writeConfig("use24hFormat", 2)
digitalclock.writeConfig("fontFamily", "Fira Sans ExtraBold")
digitalclock.writeConfig("fontStyleName", "Regular")
digitalclock.writeConfig("fontWeight", 400)
// autoFontAndSize=false above disables Plasma's normal "scale text to fill
// the panel" behavior — without an explicit fontSize the clock falls back
// to a tiny fixed 10pt. KDE's own digitalclock_migrate_font_settings.js
// (plasma-desktop) sets this to 72 for the same reason: it's a ceiling, not
// a literal size — the applet still shrinks it to fit the actual panel
// height, so this restores the auto-fit look while keeping the custom font.
digitalclock.writeConfig("fontSize", 72)
digitalclock.writeConfig("showWeekNumbers", true)

// User Switcher
var switcher = panel.addWidget("org.kde.plasma.userswitcher")
switcher.currentConfigGroup = ["General"]
switcher.writeConfig("showFace", true)
switcher.writeConfig("showName", false)
switcher.writeConfig("showTechnicalInfo", true)

// End of Top Panel creation //
