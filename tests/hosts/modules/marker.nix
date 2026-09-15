# The e2e witness: prints what a booted system can PROVE onto the serial console — that
# userspace came up, what the slot holds, and what an install landed at the key's
# destination — then powers off so qemu exits on its own.
{ pkgs, ... }:
{
  systemd.services.e2e-marker = {
    wantedBy = [ "multi-user.target" ];
    serviceConfig.Type = "oneshot";
    path = [ pkgs.age pkgs.coreutils pkgs.util-linux pkgs.systemd ];
    script = ''
      echo "E2E-BOOT-OK $(cat /proc/sys/kernel/hostname)" > /dev/console
      report_slot() {
        if [ -s /run/slot/sops.age ]; then
          echo "E2E-KEY $(age-keygen -y /run/slot/sops.age)" > /dev/console
        else
          echo "E2E-KEY-EMPTY" > /dev/console
        fi
      }
      mkdir -p /run/slot
      slot=/dev/disk/by-partlabel/secrets
      if [ -e "$slot" ]; then
        if mount -o ro "$slot" /run/slot 2>/dev/null; then
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
          echo "E2E-KEY-EMPTY" > /dev/console
        fi
      fi
      if [ -s /var/lib/sops/age.key ]; then
        echo "E2E-INSTALLED-KEY $(age-keygen -y /var/lib/sops/age.key)" > /dev/console
      fi
      side=/dev/disk/by-label/SECRETS
      if [ -e "$side" ]; then
        mkdir -p /run/sidecar
        if mount -o ro "$side" /run/sidecar 2>/dev/null; then
          if [ -s /run/sidecar/sops.age ]; then
            echo "E2E-SIDECAR $(age-keygen -y /run/sidecar/sops.age)" > /dev/console
          else
            echo "E2E-SIDECAR-EMPTY" > /dev/console
          fi
        fi
      fi
      systemctl poweroff --no-block
    '';
  };
}
