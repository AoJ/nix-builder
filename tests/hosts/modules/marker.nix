# The e2e witness: records onto the result disk (not the serial console) what a booted
# system can PROVE — that userspace came up, that the nix DB is valid, what the slot holds,
# what an install landed — then powers off so qemu exits on its own.
# slotName / slotFile come from tools — the runtime read paths (partlabel, iso file) are
# derived from the same source the image block built the slot from, not restated here.
{ record, slotName, slotFile }:
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
      slot=/dev/disk/by-partlabel/${slotName}
      iso_slot=/iso${slotFile}
      if [ -e "$slot" ]; then
        if mount -o ro "$slot" /run/slot 2>/dev/null; then
          report_slot
        fi
      elif [ -e "$iso_slot" ]; then
        if mount -o ro,loop "$iso_slot" /run/slot 2>/dev/null; then
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
      if [ -s /var/lib/sops/age.key ]; then
        e2e-record "E2E-INSTALLED-KEY $(age-keygen -y /var/lib/sops/age.key)"
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
      systemctl poweroff --no-block
    '';
  };
}
