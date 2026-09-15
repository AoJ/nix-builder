{ pkgs }:

let
  inherit (pkgs) lib;
  schema = import ./schema.nix { inherit lib; };
  d = schema.dimensions;

  zfsHost = {
    name = "ax-like";
    realization = {
      boot = "disk";
      root = { medium = "zfs"; pool = "rpool"; encryption = true; };
      delivery.modes = [ "deploy-install" "colmena" ];
      secretsTransport.kind = "sops-boot";
    };
  };
  memHost = {
    name = "pi5-like";
    realization = {
      boot = "ram";
      root.medium = "tmpfs";
      delivery.modes = [ "image" ];
      secretsTransport.kind = "baked-partition";
    };
  };
  extHost = {
    name = "iris-like";
    realization = {
      root.medium = "ext4";
      delivery.modes = [ "image" "iso-swap" ];
      secretsTransport.kind = "creds-cd";
    };
  };

  # A LIVE sample straight from the repo, so the seam is measured against today's data
  # and not against fixtures that agree with it.
  real = import ../../../tests/hosts/test-memory/host.nix;

  refused = h: !(builtins.tryEval (builtins.deepSeq (d h) true)).success;
in

assert lib.assertMsg ((d zfsHost).runtime == { mode = "disk"; storage = "zfs"; })
  "medium=zfs splits into disk/zfs";
assert lib.assertMsg ((d zfsHost).secrets.delivery == [ "deploy" ])
  "sops-boot is the deploy delivery — sops was a bundle format, not a transport";
assert lib.assertMsg ((d zfsHost).install.pool == "rpool" && (d zfsHost).install.encrypted)
  "pool and encryption ride to the install, per L2/L3";
assert lib.assertMsg ((d zfsHost).endpointsRequired == [ "image-kexec-install" ])
  "deploy-install consumes the kexec installer; colmena consumes no artifact";
assert lib.assertMsg ((d memHost).runtime == { mode = "memory"; storage = "squashfs"; })
  "medium=tmpfs splits into memory/squashfs";
assert lib.assertMsg ((d memHost).secrets.delivery == [ "embedded" ])
  "baked-partition is the embedded delivery";
assert lib.assertMsg ((d extHost).runtime == { mode = "disk"; storage = "ext4"; })
  "medium=ext4 splits into disk/ext4";
assert lib.assertMsg ((d extHost).secrets.delivery == [ "sidecar" ])
  "creds-cd is the sidecar delivery";
assert lib.assertMsg
  (lib.sort lib.lessThan (d extHost).endpointsRequired
    == [ "image-iso" "image-qcow2" "image-raw" ])
  "image + iso-swap consume the three runtime artifacts";
assert lib.assertMsg ((d real).runtime == { mode = "disk"; storage = "ext4"; })
  "the LIVE test-memory host maps to disk/ext4";
assert lib.assertMsg ((d real).endpointsRequired == [ "image-raw" "image-qcow2" ])
  "the LIVE test-memory host's image delivery consumes raw+qcow2";

assert lib.assertMsg (refused { name = "x"; realization = { boot = "ram"; root.medium = "ext4"; }; })
  "boot=ram with a disk medium is a pair that does not go together — refused, not guessed";
assert lib.assertMsg (refused { name = "x"; realization = { boot = "disk"; root.medium = "tmpfs"; }; })
  "boot=disk with a tmpfs root is refused";
assert lib.assertMsg (refused { name = "x"; realization = { }; })
  "no medium, no dimensions — refused";
assert lib.assertMsg
  (refused { name = "x"; realization = { root.medium = "ext4"; delivery.modes = [ "bogus" ]; }; })
  "an unknown delivery mode is refused";

pkgs.writeText "test-schema" "the old schema maps onto the dimensions, and contradictions refuse"
