{ pkgs }:

# The one privileged place: it assembles the tool set that every block is handed, and it is
# the only spot in the PoC that reaches into the repo's shared lib (mkBashTool + the bash
# helper lib it prepends). Only tools go in here. A block placed here would let a block
# reach a block, and the rule that keeps the dependency graph acyclic falls.
let
  bashTool = args: (import ../../../../lib/core/bashTool.nix) ({ inherit pkgs; } // args);
  ids = import ./ids.nix;
in
{
  inherit bashTool ids;
  fatImage = (import ./fat-image.nix { inherit pkgs bashTool; }).build;
  fatImageApp = (import ./fat-image.nix { inherit pkgs bashTool; }).app;
  gptDisk = import ./gpt-disk.nix { inherit pkgs bashTool ids; };
  store = import ./store.nix { inherit pkgs bashTool; };
  # The repo's ONE tested install action (disko-or-import -> place key -> nixos-install ->
  # clean export), consumed from its single source — no copy. The install block's installer
  # OS runs it; nothing reimplements the flow.
  niximilateInstall = import ../../../../lib/50_install/niximilateInstallApp.nix pkgs;
  # The read-only store mechanism (overlay + register-nix-paths) and the two runtime faces
  # built on it. A face is a nixos module, and the mechanism belongs to whoever declares the
  # read-only store — so it lives here once and every consumer imports it.
  roStore = import ./ro-store.nix { inherit pkgs; };
  netbootFace = import ./netboot-face.nix { inherit pkgs; };
  isoFace = import ./iso-face.nix { inherit pkgs; };

  # Deterministic e2e capture: append a witness line to the vfat "result" disk the harness
  # attaches (stable virtio serial e2eout), instead of racing serial output that a fast
  # guest can lose before qemu drains it. Mounts per call, so sequential writers from
  # different services are safe. The harness reads the disk with mtools after qemu exits.
  e2eRecord = pkgs.writeShellScriptBin "e2e-record" ''
    set -eu
    dev=/dev/disk/by-id/virtio-e2eout
    [ -e "$dev" ] || { echo "e2e-record: no result disk" >&2; exit 0; }
    mnt=/run/e2e-out
    # Mount ONCE and leave it: a mount/umount per call races the vfat ("device busy" on the
    # next mount before writeback settles) and silently drops lines. Shutdown unmounts and
    # flushes; the per-write sync is belt-and-braces.
    ${pkgs.coreutils}/bin/mkdir -p "$mnt"
    ${pkgs.util-linux}/bin/mountpoint -q "$mnt" \
      || ${pkgs.util-linux}/bin/mount -t vfat -o rw "$dev" "$mnt"
    ${pkgs.coreutils}/bin/printf '%s\n' "$*" >> "$mnt/log"
    ${pkgs.coreutils}/bin/sync
  '';
}
