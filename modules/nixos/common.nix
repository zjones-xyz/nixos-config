{ config, pkgs, lib, ... }:

{
  imports = [
    ./letsencrypt.nix
  ];

  nix = {
    settings = {
      experimental-features = [ "nix-command" "flakes" ];
      auto-optimise-store = true;
    };
    gc = {
      automatic = true;
      dates = "weekly";
      options = "--delete-older-than 30d";
    };
  };

  nixpkgs.config.allowUnfree = true;

  time.timeZone = "America/Los_Angeles";

  i18n.defaultLocale = "en_US.UTF-8";
  i18n.extraLocaleSettings = {
    LC_ADDRESS        = "en_US.UTF-8";
    LC_IDENTIFICATION = "en_US.UTF-8";
    LC_MEASUREMENT    = "en_US.UTF-8";
    LC_MONETARY       = "en_US.UTF-8";
    LC_NAME           = "en_US.UTF-8";
    LC_NUMERIC        = "en_US.UTF-8";
    LC_PAPER          = "en_US.UTF-8";
    LC_TELEPHONE      = "en_US.UTF-8";
    LC_TIME           = "en_US.UTF-8";
  };

  security.sudo.wheelNeedsPassword = false;

  users.users.z = {
    isNormalUser = true;
    # `docker` grants access to the rootful daemon socket (/run/docker.sock).
    # NOTE: docker-group membership is root-equivalent — keep this list tight.
    extraGroups = [ "wheel" "networkmanager" "docker" ];
    shell = pkgs.bash;
    openssh.authorizedKeys.keys = [
      "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQCfTHdojQvKOlTaaTYT2RmYMNKQ/6rBQwn6V+bPnrtASaI/G5E7RW67XGbZHi3K7EctyB9UP9Uw54sayEu4ebixI/dNFVVWeZ2byBQ49FoXh5o9Cfok0Qwf0QM7g9Td8O6Iu2ElnI8e+9cr8ThrfPpKmP68e6mpuYDvhQb4omcx8kRhxnsuNxkL2xCTNVxG/jw68o/1KHX++6tRqf0E3PBCjZ3Z8HMTdS8ouEBa8Y96GGeUvslwDJ9cUtLNCUhR5t3mGu3iSS9RYpFg/JujyTT9yhe2O/0og+OhBeSayGZMOXGWngGUEItExlbq2I4rMV5pFB1q+OyqksvlUfkJ/j3yJOii5uwonYvkWLZfR02yhn2b/bgOfYaimO5rfKj5jAC8bMRnWqLJAiG2qRDwtJT+ijyYlTKgLpz73sOGAQVvZygq11Vc35cZMFojlMeqAHdZMGi6XkUHnfZt8gyplw6VPV5EQnyDI4bRfY9sknuFvjHqdEzNyNrIEXtlmIB870s= z@Serenity.local"
    ];
  };

  environment.systemPackages = with pkgs; [
    git
    wget
    curl
    htop
    vim
    age
    ssh-to-age
    sops
  ];

  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = false;
      PermitRootLogin = "no";
    };
  };

  networking.firewall.enable = true;

  # Rootful Docker. Daemon runs as root; socket at /run/docker.sock (root:docker).
  # We moved off rootless because the uid-mapping / bind-mount-ownership friction
  # (the /run/user/1000 socket, ExecStartPre chown dances, secret-copy hacks) was
  # not worth the isolation it bought. The main rootful risk — socket access being
  # root-equivalent — is mitigated for the public-facing reverse proxy by fronting
  # the socket with a hardened proxy (see traefik.nix). A userns-remap follow-up is
  # planned to restore uid isolation once stack data ownership is normalized.
  virtualisation.docker.enable = true;

  virtualisation.docker.autoPrune = {
    enable = true;
    dates = "weekly";
  };
}
