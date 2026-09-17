# The live-ISO VARIANT: the tools' iso face plus the two things only a host context knows —
# its disk mounts must not apply beyond what the face overrides, and the medium provides no
# bootloader to install.
{ label, face }:
{ lib, ... }:
{
  imports = [ (face { inherit label; }) ];
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
