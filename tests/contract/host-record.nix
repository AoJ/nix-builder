# The record's contract, proven the way every other block's is: what it accepts, and what
# it REFUSES. The refusals are the point — before the interface existed, each of these was
# either an attribute error deep inside a block or, worse, a silently different host.
#
# Each case forces the endpoint that actually READS the field, because required fields are
# deliberately lazy: a host is only held to what its own endpoints need.
{ pkgs, tools }:

let
  inherit (pkgs) lib;
  compose = import ../../compose.nix { inherit pkgs tools; };

  toplevel = pkgs.writeText "a-toplevel" "the system";
  variant = {
    inherit toplevel;
    kernel = pkgs.writeText "kernel" "k";
    initrd = pkgs.writeText "initrd" "i";
    espBinary = pkgs.writeText "systemd-boot.efi" "b";
    kernelParams = [ ];
    rootMode = "disk";
  };
  machine = {
    kernelPackages = pkgs.linuxPackages;
    initrdAvailableKernelModules = [ "virtio_blk" ];
    initrdKernelModules = [ ];
    kernelModules = [ ];
    firmware = [ ];
  };
  liveVariant = variant // { rootMode = "memory"; };

  base = {
    name = "record-fixture";
    system = "x86_64-linux";
    slotName = "secrets";
    variants = {
      runtime = variant // { inherit machine; storage = "ext4"; };
      liveNetboot = liveVariant;
      liveIso = _label: liveVariant;
    };
    secrets = {
      delivery = [ "embedded" ];
      files = [{
        target = "/sops.age";
        content.file = "/run/secrets/host.key";
      }];
    };
    install = {
      script = pkgs.writeShellScript "prepare" "true";
      disks = [ "/dev/disk/by-id/example" ];
    };
  };

  # Three probes, one per consumer: the image path, the installer path (the only reader of
  # `machine` and of everything under `install`), and phase 2.
  image = host: (compose host).image-raw.file.drvPath;
  installer = host: (compose host).image-kexec-install.file.drvPath;
  phase2 = host: (compose host).image-personalize.run.drvPath;

  accepted = probe: host: (builtins.tryEval (probe host)).success;
  refused = probe: host: !(accepted probe host);

  withRuntime = host: r: host // {
    variants = host.variants // { runtime = r; };
  };
in

assert lib.assertMsg (accepted image base && accepted installer base && accepted phase2 base)
  "the reference record must be accepted by every consumer as it stands";

assert lib.assertMsg (refused image (removeAttrs base [ "slotName" ]))
  "a record without slotName must be refused — there is no default to fall back on";
assert lib.assertMsg (refused image (base // { slotname = "secrets"; }))
  "a misspelled field must be refused, not silently ignored";
assert lib.assertMsg (refused image (base // { system = "riscv64-linux"; }))
  "an architecture outside the set must be refused";
assert lib.assertMsg
  (refused image (withRuntime base (variant // { inherit machine; storage = "btrfs"; })))
  "a storage outside the vocabulary must be refused";
assert lib.assertMsg
  (refused image (base // { secrets = base.secrets // { delivery = [ "carrier-pigeon" ]; }; }))
  "a delivery outside the set must be refused";

assert lib.assertMsg
  (refused installer (withRuntime base (variant // { storage = "ext4"; })))
  "an installer whose host declared no machine record must be refused";
assert lib.assertMsg
  (refused installer (base // { install = removeAttrs base.install [ "disks" ]; }))
  "an installer with no disks to wipe must be refused";
assert lib.assertMsg
  (refused installer (base // { install = base.install // { encrypted = true; }; }))
  "encryption outside a zfs layout must be refused (L3)";

assert lib.assertMsg
  (refused phase2 (base // {
    secrets.delivery = [ "embedded" ];
    secrets.files = [{ target = "/x"; content = { text = "a"; env = "B"; }; }];
  }))
  "a file naming two content forms must be refused — where its bytes come from is one answer";
assert lib.assertMsg
  (refused phase2 (base // {
    secrets.delivery = [ "embedded" ];
    secrets.files = [{ target = "/x"; content = { }; }];
  }))
  "a file naming no content form at all must be refused";
assert lib.assertMsg
  (refused phase2 (base // {
    secrets.delivery = [ "embedded" ];
    secrets.files = [{ target = "relative"; content.text = "a"; }];
  }))
  "a target that is not a path inside the slot must be refused";
assert lib.assertMsg
  (accepted phase2 (base // {
    secrets.delivery = [ "embedded" ];
    secrets.files = [
      { target = "/from-text"; content.text = "already encrypted, so the store is fine"; }
      { target = "/from-env"; content.env = "SOME_VAR"; mode = "0440"; }
    ];
  }))
  "text and env are complete declarations — nothing on disk is needed to build with them";

# The other half of laziness: a host is not made to invent what it never uses. The
# appliance's endpoints are the image ones (its installers are L6 holes), and it states
# no install at all.
assert lib.assertMsg
  (accepted image (withRuntime (removeAttrs base [ "install" ])
    (variant // { inherit machine; storage = "squashfs"; rootMode = "memory"; })))
  "a host whose endpoints need no install must not have to invent one";

pkgs.writeText "test-host-record" "the host record's contract holds"
