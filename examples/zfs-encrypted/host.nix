# An encrypted zfs host — the plain zfs example plus this host's own unlock story, and NO
# hand-rolled formatting: the pool is created through disko like every other target. The
# layout template declares the encryption as data; the create reads the passphrase off the
# path the install action lays the slot out at (`builder.lib.paths.installSlot`), then
# repoints keylocation at the initrd file the installed system provides.
#
# Encryption follows the install (law L3): no image is ever encrypted — `#image-raw` stays
# a hole — because a key in a cacheable derivation is store-public for life. blocks still
# carries the `pool.pass` file into the slot and never opens it.
{ pkgs, builder, diskoModule }:

let
  device = "/dev/disk/by-id/virtio-main";
  pool = "rpool";
  slotName = "secrets";
  # Published by the builder: where the install action lays the slot's files out while it
  # runs, so disko's create finds the delivered passphrase there.
  inherit (builder.lib.paths) installSlot;
  # This host's own choices: where its slot partition mounts once installed, and the initrd
  # path stage 1 reads the passphrase from.
  slotMount = "/var/lib/slot";
  poolKeyInitrd = "/pool.key";

  configuration = { modulesPath, ... }: {
    imports = [ (modulesPath + "/profiles/qemu-guest.nix") ];
    system.stateVersion = "26.05";
    boot.loader.grub.enable = false;
    boot.kernelParams = [ "console=ttyS0" ];
    networking.hostName = "example-zfs-enc";
    users.allowNoPasswordLogin = true;

    networking.hostId = "1badb002";
    boot.supportedFilesystems = [ "zfs" ];
    boot.zfs.forceImportRoot = false;
    boot.zfs.devNodes = "/dev/disk/by-partlabel";
    fileSystems."/" = { device = "${pool}/root"; fsType = "zfs"; };
    fileSystems."/boot" = { device = "/dev/disk/by-partlabel/ESP"; fsType = "vfat"; };
    boot.loader.systemd-boot.enable = true;

    # The slot the install filled, mounted where this host wants it.
    fileSystems.${slotMount} = {
      device = "/dev/disk/by-partlabel/${slotName}";
      fsType = "vfat";
      options = [ "ro" "umask=0077" ];
    };
    # The bootloader step copies the passphrase into the initrd at every generation, so
    # stage 1 can read it before the pool unlocks — and it therefore sits in plaintext on
    # the ESP. Whether that is protection enough is this host's call.
    boot.initrd.secrets.${poolKeyInitrd} = "${slotMount}/pool.pass";
  };

  # The same template as the plain zfs host, with encryption stated as data: created
  # reading the install-slot passphrase, then repointed at the initrd path for boot.
  layout = builder.lib.diskLayoutZfs {
    inherit device slotName pool;
    # disko mounts the slot here during the install, so the bootloader step can bake the
    # passphrase into the initrd from a file that is in place before it runs.
    inherit slotMount;
    encryption = {
      keyInstall = "${installSlot}/pool.pass";
      keyBoot = poolKeyInitrd;
    };
  };

  host = import (pkgs.path + "/nixos/lib/eval-config.nix") {
    system = "x86_64-linux";
    modules = [ configuration diskoModule layout ];
  };
in
builder.lib.imagesFor {
  inherit pkgs host slotName;

  # The passphrase is ONE MORE FILE in the same delivery — the bricks combine, and blocks
  # learns nothing about what either file is for.
  secrets = {
    delivery = [ "embedded" "sidecar" ];
    files = [
      { target = "/sops.age"; content.file = "/run/secrets/example-zfs-enc/host.key"; }
      { target = "/pool.pass"; content.file = "/run/secrets/example-zfs-enc/pool.pass"; }
    ];
  };

  # Not decoration: it makes an installer whose slot never received the declared files
  # refuse BEFORE any wipe, instead of failing the create with the disk already cleared.
  install.encrypted = true;
}
