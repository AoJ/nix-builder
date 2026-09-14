{
  fileSystems."/" = {
    device = "/dev/disk/by-partlabel/nixos";
    fsType = "ext4";
  };
  fileSystems."/boot" = {
    device = "/dev/disk/by-partlabel/ESP";
    fsType = "vfat";
  };
  # The image path never runs it — the artifact's ESP is the image block's. The INSTALL
  # path does: nixos-install writes the target's own bootloader through this.
  boot.loader.systemd-boot.enable = true;
}
