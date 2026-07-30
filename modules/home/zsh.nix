{ lib, ... }:

# ─────────────────────────────────────────────────────────────────────────────
# Shared zsh completion behaviour — portable across platforms.
# ─────────────────────────────────────────────────────────────────────────────
# Imported by modules/home/interactive-zsh.nix (the NixOS hosts) and by
# hosts/serenity/home.nix (the Mac), so both get the same completion UX.
#
# Deliberately does *not* set programs.zsh.enable: shell choice stays a
# per-host decision (see modules/home/common.nix), and each importer already
# enables zsh right where it decides to use it.
{
  programs.zsh = {
    # AUTO_MENU        — a second <Tab> cycles through matches instead of
    #                    just re-printing the list. This one is already zsh's
    #                    default; pinned explicitly so an upgrade can't quietly
    #                    flip it and break the menu behaviour below.
    # COMPLETE_IN_WORD — complete from the cursor rather than only at EOL, so
    #                    fixing a typo mid-path doesn't mean retyping the tail.
    # ALWAYS_TO_END    — after accepting a completion, put the cursor at the
    #                    end of the word (not where it happened to be).
    setOptions = [
      "AUTO_MENU"
      "COMPLETE_IN_WORD"
      "ALWAYS_TO_END"
    ];

    # Rebuild the completion dump at most once a day. `compinit` walks all of
    # $fpath and security-checks every directory on each shell start; `-C`
    # skips that scan and trusts the existing dump. Cheap on the Mac, very much
    # not on the Pis (hamilton/hopper), where the full walk is a visible chunk
    # of shell startup.
    #
    # The array-assignment form is load-bearing. The widely-copied
    # `[[ -n ''${ZDOTDIR:-$HOME}/.zcompdump(#qN.mh+24) ]]` version does not
    # work: `[[ ]]` performs no filename generation, so the test sees the
    # un-globbed literal string, is always true, and silently always takes the
    # slow branch. Glob qualifiers only fire where globbing actually happens —
    # here, the right-hand side of an array assignment.
    #
    # (Nmh-24) = null_glob, modified less than 24 hours ago.
    completionInit = ''
      autoload -Uz compinit
      _zcompdump_fresh=( ''${ZDOTDIR:-$HOME}/.zcompdump(Nmh-24) )
      if (( $#_zcompdump_fresh )); then
        compinit -C
      else
        compinit
      fi
      unset _zcompdump_fresh
    '';

    # mkOrder 580 lands just after home-manager's own compinit call (570) and
    # well before its plugin sourcing (700+) — `menu select` needs the
    # complist module loaded and compinit already run.
    initContent = lib.mkOrder 580 ''
      zmodload zsh/complist

      # Arrow-key-navigable menu instead of a flat list of candidates.
      zstyle ':completion:*' menu select

      # Case-insensitive, then match on partial words split at . _ - so
      # `unlock-m<Tab>` and `foo.b<Tab>` complete the way you'd expect.
      zstyle ':completion:*' matcher-list 'm:{a-zA-Z}={A-Za-z}' 'r:|[._-]=* r:|=*'

      # Group matches by what they are (files / builtins / aliases …) with a
      # header per group, rather than one undifferentiated column.
      zstyle ':completion:*' group-name ""
      zstyle ':completion:*:descriptions' format '%F{yellow}-- %d --%f'
      zstyle ':completion:*:warnings' format '%F{red}-- no matches --%f'

      # Colour filename matches the same way ls does.
      zstyle ':completion:*' list-colors ''${(s.:.)LS_COLORS}

      # Cache the slow completers (package lists, etc.). zsh does not create
      # cache-path for us, hence the mkdir.
      _zcompcache_dir=''${XDG_CACHE_HOME:-$HOME/.cache}/zsh
      [[ -d $_zcompcache_dir ]] || mkdir -p $_zcompcache_dir
      zstyle ':completion:*' use-cache on
      zstyle ':completion:*' cache-path "$_zcompcache_dir/zcompcache"
      unset _zcompcache_dir
    '';
  };
}
