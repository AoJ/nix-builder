# The e2e witness: records onto the result disk what a booted system can PROVE — userspace
# up, the nix DB valid, what the slot holds, what an install landed — then powers off so
# qemu exits on its own.
#
# The slot locations here are RESTATED as literals ON PURPOSE — this is the gate. tools/
# slot-face.nix is the one source the image and installer share; the marker independently
# says where it EXPECTS the key, so if the image ever puts the slot somewhere else the boot
# stops finding it and the e2e goes red. A marker that derived the path from slot-face would
# only ever agree with itself.
{ record, sidecarIsoLabel ? null }:
{ pkgs, ... }:
{
  systemd.services.e2e-marker = {
    wantedBy = [ "multi-user.target" ];
    serviceConfig.Type = "oneshot";
    path = [ record pkgs.age pkgs.coreutils pkgs.util-linux pkgs.systemd pkgs.nix ];
    script = ''
      e2e-record "E2E-BOOT-OK $(cat /proc/sys/kernel/hostname)"

      # The nix DB must be VALID, not merely present: walking the running system's closure
      # reads it, and an empty DB (a registration that silently did not run) fails here
      # rather than only when something later runs nixos-install.
      if nix-store -q --requisites /run/current-system > /dev/null 2>&1; then
        e2e-record "E2E-DB-OK"
      else
        e2e-record "E2E-DB-BAD"
      fi

      report_slot() {
        if [ -s /run/slot/sops.age ]; then
          e2e-record "E2E-KEY $(age-keygen -y /run/slot/sops.age)"
        else
          e2e-record "E2E-KEY-EMPTY"
        fi
      }
      mkdir -p /run/slot
      if [ -e /dev/disk/by-partlabel/secrets ]; then
        if mount -o ro /dev/disk/by-partlabel/secrets /run/slot 2>/dev/null; then
          report_slot
        fi
      elif [ -e /iso/boot/secrets.img ]; then
        if mount -o ro,loop /iso/boot/secrets.img /run/slot 2>/dev/null; then
          report_slot
        fi
      elif [ -d /run/initrd-slot ]; then
        if [ -s /run/initrd-slot/sops.age ]; then
          cp /run/initrd-slot/sops.age /run/slot/sops.age
          report_slot
        else
          e2e-record "E2E-KEY-EMPTY"
        fi
      fi
      side=/dev/disk/by-label/SECRETS
      if [ -e "$side" ]; then
        mkdir -p /run/sidecar
        if mount -o ro "$side" /run/sidecar 2>/dev/null; then
          if [ -s /run/sidecar/sops.age ]; then
            e2e-record "E2E-SIDECAR $(age-keygen -y /run/sidecar/sops.age)"
          else
            e2e-record "E2E-SIDECAR-EMPTY"
          fi
        fi
      fi
      ${pkgs.lib.optionalString (sidecarIsoLabel != null) ''
        # The iso sidecar's label is DERIVED, not the constant SECRETS, so it CANNOT be a
        # restated literal here — it is threaded in from the same ids function a host config
        # uses (builder.lib.labels.secretsIsoLabel), and test-sidecar-identity is where that
        # value is pinned to what the medium actually carries. This proves the derive-mount
        # chain a host walks, which no literal ever exercised.
        side_iso=/dev/disk/by-label/${sidecarIsoLabel}
        if [ -e "$side_iso" ]; then
          mkdir -p /run/sidecar-iso
          if mount -o ro "$side_iso" /run/sidecar-iso 2>/dev/null; then
            if [ -s /run/sidecar-iso/sops.age ]; then
              e2e-record "E2E-SIDECAR-ISO $(age-keygen -y /run/sidecar-iso/sops.age)"
            else
              e2e-record "E2E-SIDECAR-ISO-EMPTY"
            fi
          fi
        fi
      ''}
      systemctl poweroff --no-block
    '';
  };
}
