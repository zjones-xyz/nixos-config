{ config, pkgs, lib, ... }:

let
  ca = ../../certs/bambuddy-vp-ca.crt;
  apps = [ "/Applications/OrcaSlicer.app" "/Applications/BambuStudio.app" ];
in
{
  # ── Bambuddy's virtual-printer CA in the slicers' printer.cer ──
  # The casks' printer.cer is the only store the slicers trust printers from,
  # and a cask upgrade replaces it, so every switch re-appends the CA if it's
  # missing. Runs after `brew bundle`. Failures (e.g. no App Management
  # permission) only warn. Setup and caveats: hosts/serenity/MANUAL-STEPS.md §2.
  system.activationScripts.postActivation.text = ''
    # The CA's first base64 line covers its random serial, so it identifies it.
    marker=$(sed -n 2p ${ca})
    for app in ${lib.escapeShellArgs apps}; do
      cer="$app/Contents/Resources/cert/printer.cer"
      [ -f "$cer" ] || continue
      grep -qF "$marker" "$cer" && continue
      echo "appending Bambuddy's CA to $cer"
      {
        [ -z "$(tail -c1 "$cer")" ] || echo >> "$cer"
        cat ${ca} >> "$cer"
      } || echo "warning: could not update $cer" >&2
    done
  '';
}
