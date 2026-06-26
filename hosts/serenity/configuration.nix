{ config, pkgs, lib, ... }:

# ─────────────────────────────────────────────────────────────────────────────
# Serenity — nix-darwin config for Zoe's Mac (aarch64-darwin / Apple Silicon).
# ─────────────────────────────────────────────────────────────────────────────
# Build/activate on the Mac itself:
#   nix run nix-darwin -- switch --flake .#serenity
# (The flake attribute stays lowercase `serenity` for ergonomics; the machine
# name below is the capitalised "Serenity".)
{
  networking.hostName = "Serenity";
  networking.computerName = "Serenity";

  # This Mac runs Determinate Nix, which manages the Nix installation itself.
  # nix-darwin must NOT also manage nix or the two fight over /etc/nix and the
  # daemon. Let Determinate own it.
  nix.enable = false;

  nixpkgs.hostPlatform = "aarch64-darwin";
  nixpkgs.config.allowUnfree = true;

  # Home Manager's darwin integration derives home.homeDirectory from this.
  users.users.z = {
    name = "z";
    home = "/Users/z";
  };

  # Minimal baseline. Grow as Zoe migrates Mac config into nix-darwin.
  environment.systemPackages = with pkgs; [
    git
    vim
  ];

  programs.bash.enable = true;

  # nix-darwin state version (integer, unlike NixOS). 7 is the current max for
  # nix-darwin-26.05 (config.system.maxStateVersion); valid range is 1–7.
  system.stateVersion = 7;
}
