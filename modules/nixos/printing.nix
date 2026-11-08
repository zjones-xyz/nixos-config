{ config, pkgs, lib, ... }:

{
  # ── Printing: CUPS + mDNS discovery ─────────────────────────────────────────
  # Network printers are driverless (IPP Everywhere / AirPrint): Avahi finds
  # them and CUPS builds the queue itself, so no per-printer config lives here.
  # openFirewall lets the mDNS replies past common.nix's firewall.
  services.printing = {
    enable = true;
    # Fallback for the Brother HL-L2380DW if its driverless queue misbehaves.
    drivers = [ pkgs.brlaser ];
  };

  services.avahi = {
    enable = true;
    nssmdns4 = true;
    openFirewall = true;
  };
}
