# format-vm — the ONE disk-format path that needs a kernel. disko formats a blank image
# inside a VM on the RUNNER's architecture (the layout is DATA, so its scripts are generated
# against runner pkgs — never the target's), then the closure is injected without executing
# a single target-arch binary: cp from the shared store, the runner's nix loads the db,
# symlinks make the profile, the ESP is plain files. Activation belongs to first boot.
#
# This is what dissolves L2 for an unencrypted pool: the pool is a kernel object, and here
# is the kernel to make it — born with the TARGET's hostid so first boot imports cleanly.
#
# The price, relative to the no-VM assembly: two builds of one image are NOT the same bytes.
# Every STAMP the tools expose is pinned — the VM's rtc is fixed, SOURCE_DATE_EPOCH rides
# into every mkfs, the pool GUID is reguid'ed to a name-derived value, the nix db is
# normalised — but bytes are also WHERE the kernel places writes, and allocation is
# scheduling (txg sync, writeback), which has no seed. Same inputs give the same CONTENT;
# the same-bytes gate is the assembly path's alone.
{ pkgs, bashTool }:

let
  inherit (pkgs) lib;
  diskoSrc = import ../disko-pin.nix;
  disko = import diskoSrc { inherit lib; };
  diskoLib = import (diskoSrc + "/lib") {
    inherit lib;
    makeTest = import (pkgs.path + "/nixos/tests/make-test-python.nix");
    eval-config = import (pkgs.path + "/nixos/lib/eval-config.nix");
    qemu-common = import (pkgs.path + "/nixos/lib/qemu-common.nix");
  };
in

{ name, layout, hostId ? null, storePaths, profile ? null, espFiles ? [ ],
  espMountPoint ? "/boot" }:

let
  disks = lib.attrValues (layout.disko.devices.disk or { });
  disk =
    if lib.length disks == 1 then lib.head disks
    else throw "format-vm ${name}: exactly ONE disk, the layout declares ${toString (lib.length disks)}";

  zpools = lib.attrNames (layout.disko.devices.zpool or { });
  needsZfs = zpools != [ ];
  # 15 hex digits (60 bits): a name-derived pool guid `zpool reguid -g` accepts, kept
  # under bash's signed-64 arithmetic so 16#… never overflows.
  poolGuids = lib.concatMapStringsSep " "
    (p: "${p}:${lib.substring 0 15 (builtins.hashString "sha256" "${name}:pool:${p}")}")
    zpools;
  hostIdChecked =
    if needsZfs && hostId == null
    then throw ("format-vm ${name}: a zpool is born with a hostid, and without the target's"
      + " it only imports with -f — declare networking.hostId")
    else hostId;

  # The layout with its devices rewritten to this VM's /dev/vdX — disko's own image-builder
  # move, reused so the host's REAL device names never constrain the build.
  prepared = diskoLib.testLib.prepareDiskoConfig layout diskoLib.testLib.devices;
  cfg = { disko.devices = prepared.disko.devices; };

  formatScript = disko._cliFormat cfg pkgs;
  mountScript = disko._cliMount cfg pkgs;
  unmountScript = disko._cliUnmount cfg pkgs;

  closure = pkgs.closureInfo { rootPaths = storePaths; };

  espManifest =
    if espFiles == [ ] then null
    else pkgs.writeText "${name}-esp-manifest"
      (lib.concatMapStrings (f: "${f.source}\t${f.target}\n") espFiles);

  tool = bashTool {
    name = "format-vm";
    runtimeInputs = [
      pkgs.coreutils pkgs.util-linux pkgs.nix pkgs.sqlite pkgs.jq pkgs.kmod
      pkgs.systemdMinimal pkgs.zfs
    ];
    # Everything the run needs is BAKED here (the personalize pattern): assignments keep
    # shellcheck honest about what the script reads, and the VM gets one closed executable.
    text = ''
      fv_format=${lib.escapeShellArg "${formatScript}/bin/disko-format"}
      fv_mount=${lib.escapeShellArg "${mountScript}/bin/disko-mount"}
      fv_unmount=${lib.escapeShellArg "${unmountScript}/bin/disko-unmount"}
      fv_registration=${lib.escapeShellArg "${closure}/registration"}
      fv_store_paths=${lib.escapeShellArg "${closure}/store-paths"}
      fv_profile=${lib.escapeShellArg (if profile == null then "" else "${profile}")}
      fv_esp_manifest=${lib.escapeShellArg (if espManifest == null then "" else "${espManifest}")}
      fv_esp_mount=${lib.escapeShellArg espMountPoint}
      fv_hostid=${lib.escapeShellArg (if hostIdChecked == null then "" else hostIdChecked)}
      fv_pools=${lib.escapeShellArg (lib.concatStringsSep " " zpools)}
      fv_pool_guids=${lib.escapeShellArg poolGuids}
      fv_udevd=${lib.escapeShellArg "${pkgs.systemdMinimal}"}
    '' + builtins.readFile ./format-vm.sh;
  };

  kernelPackages = pkgs.linuxPackages;
  vmTools = pkgs.vmTools.override {
    rootModules = [
      "9p" "9pnet_virtio" "virtiofs" "virtio_pci" "virtio_blk" "virtio_balloon" "virtio_rng"
      "ext4" "vfat" "nls_cp437" "nls_iso8859_1"
    ] ++ lib.optional needsZfs "zfs";
    kernel = pkgs.aggregateModules ([ kernelPackages.kernel ]
      ++ lib.optional (kernelPackages.kernel ? modules) kernelPackages.kernel.modules
      ++ lib.optional needsZfs kernelPackages.${pkgs.zfs.kernelModuleAttribute});
  };
in

vmTools.runInLinuxVM (pkgs.runCommand "${name}.img"
  {
    outputs = [ "out" "layout" ];
    memSize = 2048;
    preVM = ''
      ${pkgs.qemu-utils}/bin/qemu-img create -f raw "$out" ${disk.imageSize or "2G"}
    '';
    postVM = ''
      install -m 0644 xchg/layout.json "$layout"
    '';
    # A fixed rtc narrows every wall-clock stamp (mkfs time, zpool history, ctime) from
    # "today" to "seconds into a constant epoch" — cheap, though not byte-stability.
    QEMU_OPTS = "-rtc base=2000-01-01T00:00:00 "
      + "-drive file=\"$out\",if=virtio,cache=unsafe,werror=report,format=raw";
  }
  ''
    ${tool}/bin/format-vm
  '')
