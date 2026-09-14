{
  networking.hostId = "8425e349";
  boot.zfs.forceImportRoot = false;
  boot.supportedFilesystems = [ "zfs" ];
  fileSystems."/" = {
    device = "rpool/root";
    fsType = "zfs";
  };
  fileSystems."/boot" = {
    device = "/dev/disk/by-partlabel/ESP";
    fsType = "vfat";
  };
}
