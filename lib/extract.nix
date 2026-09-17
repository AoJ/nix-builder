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
  # The machine, as the host declares it: what an installer needs to boot exactly where
  # the host boots. A host unsure of its hardware declares the broad set in its own
  # configuration, and its installer inherits it through these same values.
  machine = {
    kernelPackages = nixos.config.boot.kernelPackages;
    initrdAvailableKernelModules = nixos.config.boot.initrd.availableKernelModules;
    initrdKernelModules = nixos.config.boot.initrd.kernelModules;
    kernelModules = nixos.config.boot.kernelModules;
    # hardware.firmware merges its definitions into ONE aggregated package (the option's
    # apply), so the extracted value is that package, re-listed for the consumer side.
    firmware = [ nixos.config.hardware.firmware ];
  };
}
