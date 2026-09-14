# The REAL extraction: an evaluated NixOS system in, derivations and strings out. This is
# the one point where the pipe's carrier changes shape, and everything a block ever sees of
# a host passes through these five lines.
nixos:
let
  toplevel = nixos.config.system.build.toplevel;
in
{
  inherit toplevel;
  kernel = "${toplevel}/kernel";
  initrd = "${toplevel}/initrd";
  kernelParams = nixos.config.boot.kernelParams ++ [ "init=${toplevel}/init" ];
}
