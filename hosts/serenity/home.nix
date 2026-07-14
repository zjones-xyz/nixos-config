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
    codex
    curl
    f3
    gh
    neovim
    nmap
    sl  # for lolz — steam locomotive when you fat-finger `ls`
    sops
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

    # 1Password CLI — used by scripts/luks-unlock-remote.sh to pull LUKS
    # passphrases via the desktop app's biometric integration instead of
    # copy-pasting from 1Password. Requires the 1Password.app "Integrate with
    # 1Password CLI" toggle enabled in Settings → Developer.
    _1password-cli

    # expect — drives the LUKS-unlock ssh session for
    # scripts/luks-unlock-remote.sh. Needed instead of a plain ssh -tt +
    # heredoc because that races systemd-tty-ask-password-agent's echo-off:
    # if the piped input lands on the remote pty before the agent disables
    # echo, it gets echoed straight back into our terminal in cleartext
    # (this happened once — see memory). expect waits for the actual prompt
    # text to appear before sending, so the agent has already disabled echo
    # by the time anything is sent.
    expect
  ];

  # zsh is the macOS default login shell; let Home Manager manage ~/.zshrc
  # (starship + direnv from common.nix hook into it automatically).
  programs.zsh.enable = true;

  # sops' age identity for this Mac. Without this, sops falls back to probing
  # default locations (~/.ssh/id_ed25519, etc.) and fails to decrypt anything
  # this admin key is a recipient for.
  home.sessionVariables = {
    SOPS_AGE_KEY_FILE = "${config.home.homeDirectory}/.config/sops/age/keys.txt";
  };

  # macOS rebuild aliases (darwin-rebuild, not nixos-rebuild). home.shellAliases
  # applies to zsh and merges with the shared `ll` from common.nix.
  #
  # unlock-memory-alpha is a thin per-host binding onto the generic
  # scripts/luks-unlock-remote.sh — add one alias like this per host rather
  # than copy-pasting the script itself.
  #
  # unlock-pegasus (2026-07-11): pegasus.internal needs an AdGuard DNS
  # rewrite pointing at pegasus's LAN IP before this resolves by name — not
  # something this repo declares (matches how memory-alpha.internal/
  # hopper.internal/hamilton.internal are all provisioned out-of-band too).
  # Until that rewrite exists, swap the hostname below for pegasus's raw LAN
  # IP. The op:// reference is safe to leave even if that 1Password item
  # doesn't exist yet — luks-unlock-remote.sh falls back to an interactive
  # passphrase prompt when the lookup fails.
  home.shellAliases = {
    drs = "sudo darwin-rebuild switch --flake ~/Code/nixos-config#serenity";
    npull = "git -C ~/Code/nixos-config pull";
    unlock-memory-alpha = ''~/Code/nixos-config/scripts/luks-unlock-remote.sh memory-alpha.internal "op://System Keys/memory-alpha luks/password"'';
    unlock-pegasus = ''~/Code/nixos-config/scripts/luks-unlock-remote.sh pegasus.internal "op://System Keys/pegasus luks/password"'';
  };

  home.stateVersion = "26.05";
}
