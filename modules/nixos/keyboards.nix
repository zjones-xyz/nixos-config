{ config, pkgs, lib, ... }:

{
  # ── Custom keyboard tooling (ZSA + QMK) ──────────────────────────────────────
  environment.systemPackages = [
    pkgs.keymapp # ZSA keyboards (Moonlander/Ergodox EZ/Voyager/Planck EZ) — live keymap configuration
    pkgs.qmk # QMK firmware CLI — building/flashing custom keyboards
  ];

  # Two genuinely different device states need separate udev rules: keymapp
  # talks to the keyboard live over hidraw at its normal runtime vendor ID
  # (3297, ZSA's own — confirmed via zsa/wally's own udev rule recommendation,
  # not covered by qmk-udev-rules at all), while qmk-udev-rules covers the
  # bootloader-mode vendor IDs (Atmel DFU, Caterina, etc.) a keyboard exposes
  # only while being flashed.
  services.udev.packages = [
    pkgs.zsa-udev-rules
    pkgs.qmk-udev-rules
  ];
}
