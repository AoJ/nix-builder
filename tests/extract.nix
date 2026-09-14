# An evaluated NixOS system in, derivations and strings out — everything a block ever sees
# of a host passes through here. rootMode is DERIVED, not declared: a tmpfs root is what
# "memory-rooted" means. The bootloader binary comes from the TARGET's own systemd, because
# the assembly tools are the runner's and never look at the payload's architecture — this
# is what keeps the arm builder out of the image path.
nixos:
let
  toplevel = nixos.config.system.build.toplevel;
  efiArch = nixos.pkgs.stdenv.hostPlatform.efiArch;
in
{
  inherit toplevel;
  kernel = "${toplevel}/kernel";
  initrd = "${toplevel}/initrd";
  kernelParams = nixos.config.boot.kernelParams ++ [ "init=${toplevel}/init" ];
  espBinary =
    "${nixos.config.systemd.package}/lib/systemd/boot/efi/systemd-boot${efiArch}.efi";
  rootMode = if nixos.config.fileSystems."/".fsType == "tmpfs" then "memory" else "disk";
}
