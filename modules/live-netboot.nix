# The netboot VARIANT: the tools' netboot face (tmpfs root, squashfs store out of the
# initrd, the initrd-slot hand-over) plus the two things only a host context knows: its
# disk mounts must not apply, and the medium provides no bootloader to install.
{ face }:
{ lib, ... }:
{
  imports = [ face ];
  fileSystems."/boot" = lib.mkForce {
    device = "none";
    fsType = "tmpfs";
    options = [ "mode=0755" ];
  };
  boot.loader.systemd-boot.enable = lib.mkForce false;
  # No bootloader install step means nothing ever appends initrd secrets — the host's
  # declared ones cannot ride a live face.
  boot.initrd.secrets = lib.mkForce { };
  boot.kernelParams = [ "boot.live" ];
}
