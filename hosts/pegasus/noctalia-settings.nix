_:

{
  # Dux runs the polkit agent in its own sessions; here Noctalia has to. Settings
  # changed in Noctalia's UI go to its own settings.toml, not this file.
  xdg.configFile."noctalia/config.toml".text = ''
    [shell]
    polkit_agent = true
  '';
}
