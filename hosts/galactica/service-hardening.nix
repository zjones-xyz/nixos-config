# The systemd hardening shared by galactica's host-local media services
# (unpackerr.nix, bazarr.nix — anything that talks to the *arrs and writes the
# shared trees). Plain attrset, not a module: consumers `import` it and merge
# their own ExecStart/ReadWritePaths (and UMask where load-bearing) with `//`.
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
