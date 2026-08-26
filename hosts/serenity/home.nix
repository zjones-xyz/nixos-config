{ config, pkgs, ... }:

{
  imports = [
    ../../modules/home/common.nix
    # Completion UX shared with the Linux hosts (which pick it up via
    # modules/home/interactive-zsh.nix — not imported here, since zsh is
    # already this host's login shell and needs no bash → zsh exec).
    ../../modules/home/zsh.nix
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
    # IPMI/BMC out-of-band management client — ipmi-sensors, ipmipower,
    # ipmiconsole (SOL), bmc-info. Serenity has no BMC of its own (no Mac
    # does), so this is purely the LAN client for talking to other machines'
    # BMCs over IPMI 2.0. nixpkgs builds it for aarch64-darwin (cached
    # upstream), so no Homebrew fallback needed.
    #
    # Its first consumer is Tower's X9SCM-F: this is how you reach the LUKS
    # passphrase prompt over serial-over-LAN and power-cycle the box when it is
    # wedged, from somewhere that is not Tower itself. FreeIPMI rather than
    # ipmitool is not a preference — that BMC needs FreeIPMI's quirks handling.
    # Exact invocations and the argument-parsing gotchas are in
    # hosts/galactica/PLATFORM.md §2.
    freeipmi
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

    # uv + Python 3.12 — for MCP servers (e.g. ~/Code/pdf-import/mcp-sourcebooks)
    # that require Python >=3.10; system Python on serenity is 3.9.6. uv can
    # manage its own Python toolchains, but pinning python312 here too means
    # `uv run --python 3.12` (or a project .python-version) resolves without
    # uv needing to download anything on first use.
    uv
    python312

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
  # The ipmi-tower-* pair binds onto scripts/ipmi-remote.sh the same way, and
  # inherits the same fallback contract — no 1Password item, no problem, it
  # drops to a local config file and then to an interactive prompt.
  #
  # towerbmc.internal resolves through an AdGuard DNS rewrite that this repo
  # does not declare — provisioned out-of-band 2026-08-09, exactly like
  # pegasus.internal above. If it ever stops resolving, the BMC's raw address
  # is 192.168.8.191 (`PLATFORM.md` §2), and swapping it means editing both
  # files (here and hosts/pegasus/home.nix).
  #
  # ⚠ These are deliberately run from *here*, not from Tower. §2: "Run these
  # from a machine that is not Tower" — the whole point of a BMC is reaching a
  # box that is wedged. pegasus carries the same two aliases so neither machine
  # being down blocks recovering the other.
  home.shellAliases = {
    drs = "sudo darwin-rebuild switch --flake ~/Code/nixos-config#serenity";
    npull = "~/Code/nixos-config/scripts/npull.sh";
    unlock-memory-alpha = ''~/Code/nixos-config/scripts/luks-unlock-remote.sh memory-alpha.internal "op://System Keys/memory-alpha luks/password"'';
    unlock-pegasus = ''~/Code/nixos-config/scripts/luks-unlock-remote.sh pegasus.internal "op://System Keys/pegasus luks/password"'';
    ipmi-tower-open-tty = ''~/Code/nixos-config/scripts/ipmi-remote.sh console towerbmc.internal "op://System Keys/tower ipmi/password"'';
    ipmi-tower-set-bios-next-boot = ''~/Code/nixos-config/scripts/ipmi-remote.sh bios-next-boot towerbmc.internal "op://System Keys/tower ipmi/password"'';
  };

  home.stateVersion = "26.05";
}
