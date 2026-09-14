{
  networking.hostId = "8425e349";
  boot.zfs.forceImportRoot = false;
  boot.supportedFilesystems = [ "zfs" ];
  # qemu virtio disks carry no by-id links; the pool's partition has a partlabel.
  boot.zfs.devNodes = "/dev/disk/by-partlabel";
  fileSystems."/" = {
    device = "rpool/root";
    fsType = "zfs";
  };
  fileSystems."/boot" = {
    device = "/dev/disk/by-partlabel/ESP";
    fsType = "vfat";
  };
  boot.loader.systemd-boot.enable = true;
}
