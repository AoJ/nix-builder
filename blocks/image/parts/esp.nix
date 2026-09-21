{ pkgs, lib, tools }:

{ name, system, bootloader, entries }:

let
  efiFileName = {
    "x86_64-linux" = "BOOTX64.EFI";
    "aarch64-linux" = "BOOTAA64.EFI";
  }.${system};

  loaderConf = pkgs.writeText "loader.conf" ''
    timeout 1
    default nixos
  '';

  entryFiles = lib.concatMap (e: [
    { source = "${e.kernel}"; target = "/${e.name}-kernel"; }
    { source = "${e.initrd}"; target = "/${e.name}-initrd"; }
    {
      source = pkgs.writeText "${e.name}.conf" ''
        title ${e.title}
        linux /${e.name}-kernel
        initrd /${e.name}-initrd
        options ${lib.concatStringsSep " " e.kernelParams}
      '';
      target = "/loader/entries/${e.name}.conf";
    }
  ]) entries;
in
rec {
  # The ESP as a FILE LIST — what the format-VM pours into a disko-made partition; the
  # image is the same list packed by fat-image for the assembly path.
  files = [
    { source = "${bootloader}"; target = "/EFI/BOOT/${efiFileName}"; }
    { source = "${loaderConf}"; target = "/loader/loader.conf"; }
  ] ++ entryFiles;

  img = tools.fatImage {
    inherit name;
    # The ESP FAT label from the ONE source the assembly's partition label also comes from.
    label = tools.diskLabels.esp;
    volumeId = tools.ids.volumeId "${name}:esp";
    inherit files;
    # FAT32 is not legal under ~33 MiB, and an ESP is FAT32 by convention.
    sizeMiB = 36;
    fat = "32";
  };
}
