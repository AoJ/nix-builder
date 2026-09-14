# The e2e witness: prints what a booted system can PROVE onto the serial console — that
# userspace came up, and what the slot holds — then powers off so qemu exits on its own.
{ pkgs, ... }:
{
  systemd.services.e2e-marker = {
    wantedBy = [ "multi-user.target" ];
    serviceConfig.Type = "oneshot";
    path = [ pkgs.age pkgs.coreutils pkgs.util-linux pkgs.systemd ];
    script = ''
      echo "E2E-BOOT-OK $(cat /proc/sys/kernel/hostname)" > /dev/console
      slot=/dev/disk/by-partlabel/secrets
      if [ -e "$slot" ]; then
        mkdir -p /run/slot
        if mount -o ro "$slot" /run/slot 2>/dev/null; then
          if [ -s /run/slot/sops.age ]; then
            echo "E2E-KEY $(age-keygen -y /run/slot/sops.age)" > /dev/console
          else
            echo "E2E-KEY-EMPTY" > /dev/console
          fi
        fi
      fi
      systemctl poweroff --no-block
    '';
  };
}
