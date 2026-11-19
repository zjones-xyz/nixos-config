#!/usr/bin/env bash
# "Ping" a USB device: send it a standard GET_STATUS control request 50 times a
# second and count the ones that fail or time out, like ping's packet loss.
# Written to check a loose connector (move the cable while it runs); works for
# any USB device.
#
# The host controller retries a failed transfer up to three times in hardware,
# so a glitch shorter than that never shows here. A lost ping means the link
# was really gone, usually a drop and re-enumeration. Audio crackle on a mic is
# below this tool's resolution.
#
# Needs root (it opens /dev/bus/usb directly) and re-runs itself under sudo.
#
# Usage: usb-ping.sh <search>
#   search — vid:pid (0d8c:0005), or any case-insensitive part of the device's
#            "vid:pid manufacturer product" (e.g. Snowball). It must match
#            exactly one device; otherwise this prints the USB tree and exits 1.
# Ctrl-C prints a ping-style summary.
set -euo pipefail

if [[ $# -ne 1 || -z $1 ]]; then
  echo "Usage: ${0##*/} <search>   (vid:pid, or part of the device name)" >&2
  exit 2
fi
if (( EUID != 0 )); then
  exec sudo -- "$(realpath -- "${BASH_SOURCE[0]}")" "$@"
fi
if ! command -v python3 >/dev/null; then
  echo "python3 not found (it's in modules/nixos/common.nix; is this host switched?)" >&2
  exit 1
fi

exec python3 - "$1" <<'PY'
import ctypes, fcntl, glob, os, sys, time

SYS = os.environ.get("USB_SYSFS", "/sys/bus/usb/devices")  # overridable for testing
want = sys.argv[1].lower()

class Ctrl(ctypes.Structure):  # struct usbdevfs_ctrltransfer
    _fields_ = [("bRequestType", ctypes.c_uint8), ("bRequest", ctypes.c_uint8),
                ("wValue", ctypes.c_uint16), ("wIndex", ctypes.c_uint16),
                ("wLength", ctypes.c_uint16), ("timeout", ctypes.c_uint32),
                ("data", ctypes.c_void_p)]
USBDEVFS_CONTROL = (3 << 30) | (ctypes.sizeof(Ctrl) << 16) | (ord("U") << 8)
buf = ctypes.create_string_buffer(2)
req = Ctrl(0x80, 0, 0, 0, 2, 200, ctypes.addressof(buf))  # GET_STATUS, 200 ms timeout

def devices():
    """Port path (usb3, 3-2, 1-4.2) -> sysfs attributes, for every USB device."""
    out = {}
    for p in glob.glob(f"{SYS}/*/idVendor"):
        d = os.path.dirname(p)
        a = {}
        for f in ("idVendor", "idProduct", "manufacturer", "product", "busnum", "devnum", "speed"):
            try:
                a[f] = open(f"{d}/{f}").read().strip()
            except OSError:
                a[f] = ""
        if a["busnum"] and a["devnum"]:
            a["label"] = f"{a['idVendor']}:{a['idProduct']} {a['manufacturer']} {a['product']}".strip()
            out[os.path.basename(d)] = a
    return out

def find():
    hits = [(k, a) for k, a in devices().items() if want in a["label"].lower()]
    return hits

def port_key(name):
    nums = name[3:] if name.startswith("usb") else name.replace("-", ".")
    return tuple(int(x) for x in nums.split(".") if x.isdigit())

def print_tree(devs):
    def children(parent):
        prefix = parent[3:] + "-" if parent.startswith("usb") else parent + "."
        return sorted((n for n in devs if n.startswith(prefix) and "." not in n[len(prefix):]
                       and not n.startswith("usb")), key=port_key)
    def show(name, depth):
        a = devs[name]
        print(f"{'  ' * depth}{name:<{12 - 2 * min(depth, 4)}} {a['label']}  [{a['speed']}M]")
        for c in children(name):
            show(c, depth + 1)
    roots = sorted((n for n in devs if n.startswith("usb")), key=port_key)
    if not roots:
        print(f"  (no USB devices under {SYS})")
    for r in roots:
        show(r, 0)

hits = find()
if len(hits) != 1:
    what = "No USB device matches" if not hits else f"{len(hits)} USB devices match"
    print(f"{what} '{sys.argv[1]}'. USB device tree:", file=sys.stderr)
    sys.stdout = sys.stderr
    print_tree(devices())
    sys.exit(1)

def node(a):
    return "/dev/bus/usb/%03d/%03d" % (int(a["busnum"]), int(a["devnum"]))

port, dev = hits[0]
path = node(dev)
print(f"pinging {dev['label']} on port {port} ({path}). Ctrl-C to stop.")

sent = lost = drops = 0
rtts, fd, down_since, last = [], None, None, 0.0
start = time.monotonic()
t = lambda: f"[{time.monotonic() - start:7.2f}s]"
CLR = "\r\033[K"
try:
    while True:
        if fd is None:
            hits = find()
            if len(hits) == 1:
                p = node(hits[0][1])
                try:
                    fd = os.open(p, os.O_RDWR)
                    if p != path:
                        print(f"{CLR}{t()} re-enumerated: {path} -> {p}")
                        path = p
                except OSError as e:
                    if sent == 0:
                        sys.exit(f"can't open {p}: {e}")
        sent += 1
        t0 = time.monotonic()
        try:
            if fd is None:
                raise OSError("device not found")
            fcntl.ioctl(fd, USBDEVFS_CONTROL, req)
            rtts.append((time.monotonic() - t0) * 1000)
            if down_since is not None:
                print(f"{CLR}{t()} back after {time.monotonic() - down_since:.2f}s")
                down_since = None
        except OSError as e:
            lost += 1
            if down_since is None:
                drops += 1
                down_since = time.monotonic()
                print(f"{CLR}{t()} \a\033[31mLOST: {e.strerror or e}\033[0m")
            if fd is not None and e.errno == 19:  # ENODEV: gone; find it again
                os.close(fd)
                fd = None
        if time.monotonic() - last > 0.25:
            last = time.monotonic()
            recent = rtts[-50:]
            avg = sum(recent) / max(len(recent), 1)
            print(f"{CLR}{t()} sent {sent}  lost {lost} ({100 * lost / sent:.2f}%)  "
                  f"dropouts {drops}  rtt {avg:.2f} ms", end="", flush=True)
        time.sleep(0.02)
except KeyboardInterrupt:
    print(f"\n--- {sent} sent, {lost} lost ({100 * lost / max(sent, 1):.2f}%), "
          f"{drops} dropouts, rtt min/avg/max "
          f"{min(rtts, default=0):.2f}/{sum(rtts) / max(len(rtts), 1):.2f}/{max(rtts, default=0):.2f} ms")
PY
