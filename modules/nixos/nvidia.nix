{ config, pkgs, lib, ... }:

{
  # ── NVIDIA proprietary driver (RTX 4070, Ada) ───────────────────────────────
  # Ada-generation cards run fine on the current proprietary driver with the
  # OPEN kernel modules (hardware.nvidia.open = true). This is the supported
  # path for Turing and newer — do NOT pin a legacy driver here.
  #
  # The dual-GTX-1070 (Pascal) box is a SEPARATE node precisely because adding
  # Pascal cards would force this whole host onto the frozen 580 legacy branch.
  services.xserver.videoDrivers = [ "nvidia" ];

  hardware.graphics = {
    enable = true;
    enable32Bit = true; # 32-bit GL for Steam/Proton
  };

  hardware.nvidia = {
    modesetting.enable = true;
    open = true; # open kernel modules — supported on Ada
    nvidiaSettings = true;
    # `production` is the conservative default (well-tested). Swap to
    # `config.boot.kernelPackages.nvidiaPackages.latest` if a needed fix or
    # newer-GPU support lands there — see hosts/pegasus/DECISIONS.md.
    #
    # `.open` (not `.mod` — that's the closed-source module path, unused
    # here since `open = true` above) fails to build against kernel 7.2:
    # kernel 7.2 dropped strncpy()'s declaration from <linux/string.h>
    # entirely (only strscpy() remains — confirmed directly against
    # `linuxPackages_latest.kernel.dev`'s headers for this pin; strcpy,
    # memcpy, and the rest are untouched). nvidia-open 595.71.05 still
    # calls strncpy() directly in four spots: kernel-open/nvidia/os-interface.c,
    # kernel-open/nvidia/linux_nvswitch.c (x2), kernel-open/nvidia-uvm/uvm_pmm_gpu.c,
    # and kernel-open/nvidia-modeset/nvidia-modeset-linux.c (NVIDIA's own
    # nvkms_strncpy wrapper). `#define`s a local compat shim with strncpy's
    # exact classic semantics (fixed-length copy, zero-pad remainder, no
    # guaranteed NUL-termination) into each, rather than switching call
    # sites to strscpy() and risking a padding/truncation behavior change.
    # Not yet patched upstream in nixpkgs as of this pin. Safe to drop once
    # nixpkgs' nvidia-x11 expression picks up a fix (or a newer driver
    # version that no longer calls strncpy()).
    package = config.boot.kernelPackages.nvidiaPackages.production // {
      open = config.boot.kernelPackages.nvidiaPackages.production.open.overrideAttrs (old: {
        postPatch = (old.postPatch or "") + ''
          cat > "$TMPDIR/nv-strncpy-compat.h" <<'EOF'
          #include <linux/string.h>
          static inline char *nv_compat_strncpy(char *dest, const char *src, size_t n)
          {
              size_t i;
              for (i = 0; i < n && src[i] != '\0'; i++)
                  dest[i] = src[i];
              for (; i < n; i++)
                  dest[i] = '\0';
              return dest;
          }
          #define strncpy nv_compat_strncpy
          EOF
          for f in kernel-open/nvidia/os-interface.c \
                   kernel-open/nvidia/linux_nvswitch.c \
                   kernel-open/nvidia-uvm/uvm_pmm_gpu.c \
                   kernel-open/nvidia-modeset/nvidia-modeset-linux.c; do
            sed -i "0r $TMPDIR/nv-strncpy-compat.h" "$f"
          done
        '';
      });
    };
  };
}
