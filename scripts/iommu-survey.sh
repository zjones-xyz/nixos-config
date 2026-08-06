#!/usr/bin/env bash
# IOMMU group survey — run at the machine, bring the output back.
#
# Answers the three questions you cannot answer from a config session:
#   1. What are the actual IOMMU groups, and which are cleanly passable?
#   2. Which PCI controller is a given USB port behind?
#   3. Therefore: can that controller be passed through on its own?
#
# Usage:
#   ./iommu-survey.sh                 # groups + USB controller map
#   ./iommu-survey.sh /dev/sdc        # ...plus: trace this device to its
#                                     #   controller and IOMMU group
#
# REQUIRES intel_iommu=on. /sys/kernel/iommu_groups is empty or absent
# otherwise, and the script will tell you so rather than silently reporting
# nothing. On bare-metal Unraid, check `cat /proc/cmdline` first; if it is
# missing, add it to the syslinux append line, reboot, survey, and revert.
# That change touches only the boot flag — not the array.
set -uo pipefail

have() { command -v "$1" >/dev/null 2>&1; }
have lspci || { echo "lspci not found (install pciutils)" >&2; exit 1; }

hr() { printf '%s\n' "────────────────────────────────────────────────────────────"; }

# ── 1. IOMMU groups ──────────────────────────────────────────────────────────
hr; echo "IOMMU GROUPS"; hr

if [ ! -d /sys/kernel/iommu_groups ] || [ -z "$(ls -A /sys/kernel/iommu_groups 2>/dev/null)" ]; then
  echo "No IOMMU groups exposed."
  echo
  echo "  /proc/cmdline: $(cat /proc/cmdline 2>/dev/null)"
  echo
  echo "  intel_iommu=on is missing, or VT-d is disabled in firmware."
  echo "  Everything below about groups will be empty until that is fixed."
else
  # Sort numerically by group, and mark groups holding exactly one device —
  # those are the ones that can be passed through without dragging a
  # neighbour along.
  for d in /sys/kernel/iommu_groups/*/devices/*; do
    g=${d#/sys/kernel/iommu_groups/}; g=${g%%/*}
    printf '%s\t%s\n' "$g" "${d##*/}"
  done | sort -n -k1,1 | {
    prev=""; buf=""
    while IFS=$'\t' read -r g addr; do
      desc=$(lspci -nns "$addr" 2>/dev/null | cut -d' ' -f2-)
      [ -z "$desc" ] && desc="(unknown)"
      if [ "$g" != "$prev" ]; then
        [ -n "$prev" ] && printf '%s' "$buf"
        prev="$g"; buf=""
        count=$(ls /sys/kernel/iommu_groups/"$g"/devices 2>/dev/null | wc -l)
        if [ "$count" -eq 1 ]; then mark="  ← isolated, cleanly passable"; else mark="  ← $count devices, ALL move together"; fi
        buf="$(printf '\ngroup %-3s%s\n' "$g" "$mark")"
      fi
      buf="${buf}$(printf '  %-13s %s\n' "$addr" "$desc")"$'\n'
    done
    printf '%s' "$buf"
  }
fi

# ── 2. USB controllers ───────────────────────────────────────────────────────
echo; hr; echo "USB CONTROLLERS (and their groups)"; hr
echo
for u in /sys/bus/usb/devices/usb*; do
  [ -e "$u" ] || continue
  bus=${u##*/}
  pci=$(basename "$(readlink -f "$u/..")")
  case "$pci" in
    *:*:*.*) ;;
    *) pci="(not a PCI device)";;
  esac
  grp="-"
  if [ -e "/sys/bus/pci/devices/$pci/iommu_group" ]; then
    grp=$(basename "$(readlink -f "/sys/bus/pci/devices/$pci/iommu_group")")
  fi
  desc=$(lspci -nns "$pci" 2>/dev/null | cut -d' ' -f2-)
  printf '  %-6s  pci %-13s  group %-4s  %s\n' "$bus" "$pci" "$grp" "${desc:-}"
done

echo
echo "  Device tree (which physical port hangs off which controller):"
if have lsusb; then lsusb -t 2>/dev/null | sed 's/^/    /'; else echo "    lsusb not found (install usbutils)"; fi

# ── 3. Trace a specific device ───────────────────────────────────────────────
if [ $# -ge 1 ]; then
  dev=$1
  echo; hr; echo "TRACE: $dev"; hr; echo
  name=$(basename "$(readlink -f "$dev" 2>/dev/null)" 2>/dev/null)
  syspath=$(readlink -f "/sys/block/$name" 2>/dev/null)
  if [ -z "$syspath" ] || [ ! -e "$syspath" ]; then
    echo "  Could not resolve $dev to a /sys/block entry."
    echo "  Pass a whole-disk node such as /dev/sdc (not a partition)."
    exit 0
  fi
  echo "  sysfs: $syspath"
  echo

  # Walk up the sysfs chain to the nearest PCI device — that is the controller.
  p=$syspath; pci=""
  while [ "$p" != "/" ] && [ -n "$p" ]; do
    b=$(basename "$p")
    if [ -e "/sys/bus/pci/devices/$b" ]; then pci=$b; break; fi
    p=$(dirname "$p")
  done

  if [ -z "$pci" ]; then
    echo "  No PCI ancestor found."
  else
    desc=$(lspci -nns "$pci" 2>/dev/null | cut -d' ' -f2-)
    grp="-"
    [ -e "/sys/bus/pci/devices/$pci/iommu_group" ] && \
      grp=$(basename "$(readlink -f "/sys/bus/pci/devices/$pci/iommu_group")")
    echo "  behind controller : $pci  $desc"
    echo "  IOMMU group       : $grp"
    if [ "$grp" != "-" ]; then
      n=$(ls "/sys/kernel/iommu_groups/$grp/devices" 2>/dev/null | wc -l)
      echo "  group members     : $n"
      for m in /sys/kernel/iommu_groups/"$grp"/devices/*; do
        md=$(lspci -nns "${m##*/}" 2>/dev/null | cut -d' ' -f2-)
        echo "      ${m##*/}  $md"
      done
      if [ "$n" -eq 1 ]; then
        echo
        echo "  → This controller is isolated. It CAN be passed through whole."
      else
        echo
        echo "  → Passing this controller means passing all $n devices above."
      fi
    fi
  fi

  # USB identity — this is what an Unraid licence is keyed on.
  echo
  echo "  USB identity (vendor:product:serial — what the licence GUID is built from):"
  usbdev=$syspath
  while [ "$usbdev" != "/" ] && [ -n "$usbdev" ]; do
    if [ -e "$usbdev/idVendor" ] && [ -e "$usbdev/idProduct" ]; then
      printf '    idVendor  : %s\n' "$(cat "$usbdev/idVendor")"
      printf '    idProduct : %s\n' "$(cat "$usbdev/idProduct")"
      printf '    serial    : %s\n' "$(cat "$usbdev/serial" 2>/dev/null || echo '(none)')"
      printf '    usb path  : %s\n' "$(basename "$usbdev")"
      break
    fi
    usbdev=$(dirname "$usbdev")
  done
  [ "$usbdev" = "/" ] && echo "    (not a USB device)"
fi

echo
