# The systemd hardening shared by galactica's host-local media services
# (unpackerr.nix, bazarr.nix — anything that talks to the *arrs and writes the
# shared trees). Plain attrset, not a module. Merge contract: this set goes on
# the LEFT of `//` so a consumer's own keys always win.
{
  NoNewPrivileges = true;
  PrivateDevices = true;
  PrivateTmp = true;
  ProtectControlGroups = true;
  ProtectHome = true;
  ProtectHostname = true;
  ProtectKernelLogs = true;
  ProtectKernelModules = true;
  ProtectKernelTunables = true;
  ProtectSystem = "strict";
  RestrictNamespaces = true;
  RestrictRealtime = true;
  RestrictSUIDSGID = true;
  SystemCallArchitectures = "native";
  LockPersonality = true;
}
