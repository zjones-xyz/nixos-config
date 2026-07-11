{ config, pkgs, claudeDesktop, ... }:

{
  imports = [
    ../../modules/home/common.nix
  ];

  home.username = "z";
  home.homeDirectory = "/home/z";

  # Host-specific rebuild aliases (layered on top of the shared portable ones
  # from modules/home/common.nix's home.shellAliases).
  programs.bash.enable = true;
  programs.bash.shellAliases = {
    nrs = "sudo nixos-rebuild switch --flake ~/nixos-config#pegasus";
    nrt = "sudo nixos-rebuild test --flake ~/nixos-config#pegasus";
    npull = "git -C ~/nixos-config pull";
  };

  # ── Desktop apps ────────────────────────────────────────────────────────────
  # allowUnfree is already set globally in modules/nixos/common.nix, which
  # pegasus imports — vscode/google-chrome/vivaldi/1Password/discord/spotify/
  # ticktick/obsidian/bambu-studio are all unfree and need it; firefox/
  # ferdium/openscad/orca-slicer/streamdeck-ui are free/open.
  #
  # Brain.fm was left out — no nixpkgs package, no native Linux client
  # anywhere (subscription web app only); usable via firefox/chrome.
  home.packages = with pkgs; [
    vscode
    google-chrome
    firefox
    vivaldi
    _1password-gui
    _1password-cli
    claude-code
    discord
    ferdium
    bambu-studio
    orca-slicer
    openscad
    obsidian
    spotify
    ticktick
    prusa-slicer
    jellyfin-desktop
    vlc

    # itch.io's official client — handles login/library/downloads/updates.
    # lutris has no native itch.io integration (no account sync), so this is
    # the actual client, not a duplicate of lutris's job.
    itch

    # Qt6 build (not plain libreoffice) for native Plasma 6 theming/integration
    # rather than pulling in GTK.
    libreoffice-qt6

    # Elgato Stream Deck control — needs the udev rule in
    # hosts/pegasus/configuration.nix for non-root USB access.
    streamdeck-ui

    # Streaming/capture — added alongside streamdeck-ui, which is otherwise a
    # control surface with nothing to control.
    obs-studio

    # GPU monitoring — htop-equivalent for the 4070, useful for confirming
    # ollama.nix's gaming-drain oneshot is actually freeing VRAM/compute.
    nvtopPackages.nvidia

    # Archive handling — wasn't anywhere in the package set (system or home).
    unzip
    p7zip

    # Winetricks operations scoped to a specific Proton prefix — common
    # companion to protonup-qt/lutris for troubleshooting individual games.
    protontricks
  ] ++ [
    # Claude Desktop — not in nixpkgs (Anthropic's official Linux beta only
    # shipped 2026-06-30, too recent). claudeDesktop comes from the
    # claude-desktop-debian flake input via home-manager.extraSpecialArgs in
    # flake.nix — the FHS-wrapped variant, needed for MCP servers to work
    # (they shell out to npx/uvx/etc. expecting a standard FHS layout).
    claudeDesktop
  ];

  # ── Declarative Plasma 6 (plasma-manager) ───────────────────────────────────
  # plasma-manager's HM module is wired in via home-manager.sharedModules in
  # flake.nix. This is a minimal starting point — Plasma writes a lot of state,
  # so grow this incrementally (export current settings with `plasma-manager`'s
  # rc2nix). See hosts/pegasus/DECISIONS.md.
  programs.plasma = {
    enable = true;
    workspace.lookAndFeel = "org.kde.breezedark.desktop";
  };

  home.stateVersion = "26.05";
}
