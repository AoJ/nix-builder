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
tools.fatImage {
  inherit name;
  label = "ESP";
  volumeId = tools.ids.volumeId "${name}:esp";
  files = [
    { source = "${bootloader}"; target = "/EFI/BOOT/${efiFileName}"; }
    { source = "${loaderConf}"; target = "/loader/loader.conf"; }
  ] ++ entryFiles;
  # FAT32 is not legal under ~33 MiB, and an ESP is FAT32 by convention.
  slackMiB = 36;
  fat = "32";
}
