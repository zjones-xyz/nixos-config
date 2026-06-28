{ config, pkgs, lib, ... }:

{
  # ── Homebrew (declarative package selection) ────────────────────────────────
  # nix-darwin's homebrew module manages WHAT is installed by running
  # `brew bundle` on activation. It does not install Homebrew itself — brew stays
  # self-installed at /opt/homebrew. Requires system.primaryUser (set in the host
  # config). This replaces the old free-standing repo-root Brewfile.
  homebrew = {
    enable = true;

    onActivation = {
      # The declared lists below are authoritative: anything installed but not
      # listed is uninstalled on switch (dependencies are kept).
      cleanup = "uninstall";
      autoUpdate = false; # don't `brew update` on every switch
      upgrade = false; # don't upgrade installed packages on switch (flip if wanted)
    };

    # homebrew/cask-drivers was archived upstream (merged into homebrew/cask);
    # qmk-toolbox now resolves from the default cask source, so it's dropped.
    taps = [
      "ferdium/ferdium"
      "macos-fuse-t/cask"
    ];

    # Plain cross-platform CLI tools that nixpkgs provides are kept in nix
    # instead (see hosts/serenity/home.nix). Homebrew keeps only what's awkward
    # to get from nixpkgs on darwin: asdf (shell-integrated runtime manager),
    # handbrake (CLI), and immich-go.
    brews = [
      "asdf"
      "handbrake"
      "immich-go"
    ];

    casks = [
      "affine"
      "alfred"
      "antigravity"
      "antigravity-cli"
      "antigravity-ide"
      "arc"
      "balenaetcher"
      "claude"
      "ferdium"
      "fuse-t"
      "macos-fuse-t/cask/fuse-t-sshfs"
      "makemkv"
      "openscad"
      "opera"
      "orcaslicer"
      "qmk-toolbox"
      "serial"
      "steam"
      "ticktick"
      "warp"
    ];
  };
}
