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
loadTemplate("org.garuda.desktop.defaultPanel")

// Create Bottom Panel (Dock)
loadTemplate("org.garuda.desktop.defaultDock")


// Configure Contextual Menu Plugin
// Targets the global [ActionPlugins][0][RightButton;NoModifier] section
// \x1d is KConfig's internal nested group separator
const desktoprc = ConfigFile('plasma-org.kde.plasma.desktop-appletsrc')
desktoprc.group = "ActionPlugins\x1d0\x1dRightButton;NoModifier"

// System Actions
desktoprc.writeEntry('_run_command', true)          // KRunner (Run Command)
desktoprc.writeEntry('_lock_screen', true)          // Lock Screen
desktoprc.writeEntry('_logout', true)               // Show Logout Screen
desktoprc.writeEntry('_open_terminal', true)        // Open Terminal

// Desktop & Display
desktoprc.writeEntry('_context', true)              // Contextual Actions
desktoprc.writeEntry('_display_settings', true)     // Display Settings
desktoprc.writeEntry('_wallpaper', true)            // Wallpaper Settings

// Desktop Management
desktoprc.writeEntry('add widgets', true)           // Add Widgets
desktoprc.writeEntry('_add panel', true)            // Add Panel
desktoprc.writeEntry('configure', true)             // Configure Desktop
desktoprc.writeEntry('configure shortcuts', false)  // Configure Shortcuts (disabled)
desktoprc.writeEntry('desktop edit mode', true)     // Enter Edit Mode
desktoprc.writeEntry('manage activities', true)     // Manage Activities
desktoprc.writeEntry('remove', true)                // Remove

// Separators
desktoprc.writeEntry('_sep1', true)
desktoprc.writeEntry('_sep2', true)
desktoprc.writeEntry('_sep3', true)
desktoprc.writeEntry('_sep4', true)


// Fast-subset build (see hosts/pegasus/DECISIONS.md): upstream sets the
// a2n.blur wallpaper plugin here, which isn't packaged in this round —
// falls back to the real Malefor wallpaper via the stock image plugin
// instead of leaving whatever default was there, or erroring on an unknown
// plugin ID.
var allDesktops = desktops();
for (i=0;i<allDesktops.length;i++){
  d = allDesktops[i];
  d.wallpaperPlugin = "org.kde.image";
  d.currentConfigGroup = Array("Wallpaper", "org.kde.image", "General");
  d.writeConfig("Image", "file:///run/current-system/sw/share/wallpapers/Malefor/contents/images/3840x1920.jpg");
}
