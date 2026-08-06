#!/usr/bin/env bash
# IOMMU group survey — run at the machine, bring the output back.
#
# Answers the three questions you cannot answer from a config session:
#   1. What are the actual IOMMU groups, and which are cleanly passable?
#   2. Which PCI controller is a given USB port behind?
#   3. Therefore: can that controller be passed through on its own?
#
# Usage:
#   ./iommu-survey.sh                 # everything, including auto-detected
#                                     #   USB storage — no arguments needed
#   ./iommu-survey.sh /dev/sdc ...    # additionally trace specific devices
#
# The zero-argument form is the useful one for port mapping: plug flash drives
# into the ports you want to identify, run it, and every USB storage device is
# reported with its controller, IOMMU group and USB identity. Plug several in at
# once — they are distinguished by model and serial.
#
# REQUIRES intel_iommu=on. /sys/kernel/iommu_groups is empty or absent
# otherwise, and the script says so rather than silently reporting nothing. On
# bare-metal Unraid, check `cat /proc/cmdline` first; if it is missing, add it to
# the syslinux append line, reboot, survey, and revert. That change touches only
# the boot flag — not the array.
set -uo pipefail

have() { command -v "$1" >/dev/null 2>&1; }
have lspci || { echo "lspci not found (install pciutils)" >&2; exit 1; }

hr() { printf '%s\n' "────────────────────────────────────────────────────────────"; }

# Nearest PCI ancestor of a sysfs path — i.e. the controller behind the device.
pci_ancestor() {
  local p=$1 b
  while [ -n "$p" ] && [ "$p" != "/" ]; do
    b=$(basename "$p")
    if [ -e "/sys/bus/pci/devices/$b" ]; then printf '%s' "$b"; return 0; fi
    p=$(dirname "$p")
  done
  return 1
}

# Nearest USB *device* ancestor — the node carrying idVendor/idProduct/serial,
# which is what an Unraid licence GUID is built from.
usb_ancestor() {
  local p=$1
  while [ -n "$p" ] && [ "$p" != "/" ]; do
    if [ -e "$p/idVendor" ] && [ -e "$p/idProduct" ]; then printf '%s' "$p"; return 0; fi
    p=$(dirname "$p")
  done
  return 1
}

group_of() {
  local pci=$1
  [ -e "/sys/bus/pci/devices/$pci/iommu_group" ] || { printf -- '-'; return; }
  basename "$(readlink -f "/sys/bus/pci/devices/$pci/iommu_group")"
}

group_size() {
  local g=$1
  [ "$g" = "-" ] && { printf '0'; return; }
  ls "/sys/kernel/iommu_groups/$g/devices" 2>/dev/null | wc -l
}

desc_of() { lspci -nns "$1" 2>/dev/null | cut -d' ' -f2-; }

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
  for g in $(ls /sys/kernel/iommu_groups | sort -n); do
    n=$(group_size "$g")
    if [ "$n" -eq 1 ]; then mark="isolated — cleanly passable"
    else mark="$n devices — ALL move together"; fi
    printf '\ngroup %-3s  (%s)\n' "$g" "$mark"
    for d in /sys/kernel/iommu_groups/"$g"/devices/*; do
      a=${d##*/}
      printf '  %-13s %s\n' "$a" "$(desc_of "$a")"
    done
  done
fi

# ── 2. USB controllers ───────────────────────────────────────────────────────
echo; hr; echo "USB CONTROLLERS (and their groups)"; hr
echo
found=0
for u in /sys/bus/usb/devices/usb*; do
  [ -e "$u" ] || continue
  found=1
  bus=${u##*/}
  pci=$(basename "$(readlink -f "$u/..")")
  case "$pci" in *:*:*.*) ;; *) pci="";; esac
  if [ -n "$pci" ]; then
    g=$(group_of "$pci")
    printf '  %-6s  pci %-13s  group %-4s  %s\n' "$bus" "$pci" "$g" "$(desc_of "$pci")"
  else
    printf '  %-6s  (not behind a PCI device)\n' "$bus"
  fi
done
[ "$found" -eq 0 ] && echo "  (no USB controllers found)"

echo
echo "  Device tree — which physical port hangs off which controller:"
if have lsusb; then lsusb -t 2>/dev/null | sed 's/^/    /'; else echo "    lsusb not found (install usbutils)"; fi

# ── 3. USB storage, auto-detected ────────────────────────────────────────────
# The port-mapping workhorse: plug drives into the ports you want to identify,
# run with no arguments, read off the controller and group for each.
echo; hr; echo "USB STORAGE DEVICES (auto-detected)"; hr
echo
any=0
for blk in /sys/block/*; do
  [ -e "$blk" ] || continue
  real=$(readlink -f "$blk")
  # Non-USB block devices have no USB ancestor and are skipped here.
  usbnode=$(usb_ancestor "$real") || continue
  any=1
  name=$(basename "$blk")
  pci=$(pci_ancestor "$real") || pci=""
  g="-"; n=0
  if [ -n "$pci" ]; then g=$(group_of "$pci"); n=$(group_size "$g"); fi

  size=$(cat "$blk/size" 2>/dev/null || echo 0)
  human=$(awk -v s="$size" 'BEGIN{printf "%.1fG", s*512/1024/1024/1024}')

  echo "  /dev/$name  ($human)"
  printf '    model     : %s %s\n' \
    "$(cat "$usbnode/manufacturer" 2>/dev/null || echo '?')" \
    "$(cat "$usbnode/product" 2>/dev/null || echo '?')"
  printf '    usb id    : %s:%s  serial %s\n' \
    "$(cat "$usbnode/idVendor" 2>/dev/null)" \
    "$(cat "$usbnode/idProduct" 2>/dev/null)" \
    "$(cat "$usbnode/serial" 2>/dev/null || echo '(none)')"
  printf '    usb path  : %s   ← note which PHYSICAL port this is\n' "$(basename "$usbnode")"
  if [ -n "$pci" ]; then
    printf '    controller: %s  %s\n' "$pci" "$(desc_of "$pci")"
    if [ "$n" -eq 1 ]; then
      printf '    group     : %s (isolated — this controller CAN be passed through whole)\n' "$g"
    else
      printf '    group     : %s (%s devices — passing this controller passes all of them)\n' "$g" "$n"
      for m in /sys/kernel/iommu_groups/"$g"/devices/*; do
        printf '                  %s  %s\n' "${m##*/}" "$(desc_of "${m##*/}")"
      done
    fi
  fi
  echo
done
if [ "$any" -eq 0 ]; then
  echo "  None found. Plug a flash drive into the port you want to identify and re-run."
  echo
fi
cat <<'NOTE'
  Reading this for licence-key placement:

    - The group only matters if you intend <hostdev type='pci'> of the whole
      controller. For <hostdev type='usb'> (QEMU usb-host, which forwards one
      physical device and preserves its vendor:product:serial) the host keeps
      the controller and the group is irrelevant.
    - "usb path" is the topology address, not a physical label. Write down which
      port you actually used — the script cannot know "rear panel, top left".
NOTE

# ── 4. Explicit traces ───────────────────────────────────────────────────────
for dev in "$@"; do
  echo; hr; echo "TRACE: $dev"; hr; echo
  name=$(basename "$(readlink -f "$dev" 2>/dev/null)" 2>/dev/null)
  syspath=$(readlink -f "/sys/block/$name" 2>/dev/null)
  if [ -z "$syspath" ] || [ ! -e "$syspath" ]; then
    echo "  Could not resolve $dev to a /sys/block entry."
    echo "  Pass a whole-disk node such as /dev/sdc (not a partition)."
    continue
  fi
  echo "  sysfs: $syspath"
  if pci=$(pci_ancestor "$syspath"); then
    g=$(group_of "$pci"); n=$(group_size "$g")
    echo "  controller : $pci  $(desc_of "$pci")"
    echo "  group      : $g ($n device(s))"
    [ "$g" != "-" ] && for m in /sys/kernel/iommu_groups/"$g"/devices/*; do
      echo "      ${m##*/}  $(desc_of "${m##*/}")"
    done
  else
    echo "  No PCI ancestor found."
  fi
  if usbnode=$(usb_ancestor "$syspath"); then
    echo "  usb id     : $(cat "$usbnode/idVendor" 2>/dev/null):$(cat "$usbnode/idProduct" 2>/dev/null)  serial $(cat "$usbnode/serial" 2>/dev/null || echo '(none)')"
  else
    echo "  (not a USB device)"
  fi
done

echo
