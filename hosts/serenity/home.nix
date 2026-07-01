{ config, pkgs, ... }:

{
  imports = [
    ../../modules/home/common.nix
  ];

  home.username = "z";
  home.homeDirectory = "/Users/z";

  # CLI tools moved off Homebrew — nixpkgs provides these (jq already comes from
  # modules/home/common.nix). Could be promoted to common.nix later if wanted on
  # the Linux hosts too.
  home.packages = with pkgs; [
    bash
    claude-code
    curl
    f3
    gh
    neovim
    nmap
    unzip
    wget

    # ── Backend / frontend dev tooling ─────────────────────────────────────
    # .NET 8 SDK — nixpkgs build is not broken on aarch64-darwin (meta.broken=false).
    # If you hit runtime linker issues or SDK resolution problems, remove this line
    # and add "dotnet-sdk" to the Homebrew casks in modules/darwin/homebrew.nix
    # as a fallback. Note: dotnet-ef (EF Core CLI) is NOT packaged in Nix or
    # Homebrew — install it per-project: dotnet tool install --global dotnet-ef
    dotnet-sdk_8
    nodejs_22    # Node 22 LTS (nodejs_20 is EOL Apr 2026, flagged insecure in nixpkgs)
    sqlite       # sqlite3 CLI
    httpie       # HTTPie — manual API endpoint testing (http/https commands)
    sqlitebrowser  # GUI SQLite viewer (Qt; nixpkgs build supports aarch64-darwin)
  ];

  # zsh is the macOS default login shell; let Home Manager manage ~/.zshrc
  # (starship + direnv from common.nix hook into it automatically).
  programs.zsh.enable = true;

  # macOS rebuild aliases (darwin-rebuild, not nixos-rebuild). home.shellAliases
  # applies to zsh and merges with the shared `ll` from common.nix.
  home.shellAliases = {
    drs = "sudo darwin-rebuild switch --flake ~/Code/nixos-config#serenity";
    npull = "git -C ~/Code/nixos-config pull";
  };

  home.stateVersion = "26.05";
}
