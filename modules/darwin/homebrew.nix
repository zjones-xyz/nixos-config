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
      # listed is uninstalled on switch (dependencies are kept). Currently a
      # no-op — installed state already matches these lists.
      cleanup = "uninstall";
      autoUpdate = false; # don't `brew update` on every switch
      upgrade = false; # don't upgrade installed packages on switch (flip if wanted)
    };

    taps = [
      "ferdium/ferdium"
      "macos-fuse-t/cask"
      # NOTE: deprecated/archived upstream (merged into homebrew/cask). Kept for
      # a faithful migration; safe to drop once qmk-toolbox is confirmed to
      # resolve from the default cask source (cleanup will then untap it).
      "homebrew/cask-drivers"
    ];

    brews = [
      "asdf"
      "bash"
      "curl"
      "f3"
      "gh"
      "handbrake"
      "immich-go"
      "jq"
      "neovim"
      "nmap"
      "unzip"
      "wget"
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
      "ticktick"
    ];
  };
}
