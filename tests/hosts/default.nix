# REAL hosts for the composer: each is an evaluated nixosSystem, and the composer's host
# record is produced by the one explicit extraction. The set spans the dimensions — disk vs
# memory, ext4 vs squashfs vs zfs, secrets delivered vs none — because that is what a
# hand-assembled record cannot prove.
{ pkgs }:

let
  fixture = import ../../blocks-poc/blocks/personalize/fixture.nix { inherit pkgs; };
  extract = import ../extract.nix;

  evalHost = modules:
    import (pkgs.path + "/nixos/lib/eval-config.nix") {
      system = "x86_64-linux";
      inherit modules;
    };

  syntheticInstall = {
    prepare = pkgs.writeShellScript "prepare" "sgdisk --zap-all /dev/target";
    mount = pkgs.writeShellScript "mount" "mount /dev/target-root \"$1\"";
    keyDestination = "/var/lib/sops/age.key";
  };

  noSecrets = {
    delivery = [ ];
    files = [ ];
  };

  withSecrets = {
    delivery = [ "embedded" "sidecar" ];
    bundle = "${fixture}/bundle.yaml";
    keyTarget = "/sops.age";
    files = [{
      target = "/sops.age";
      source = "${fixture}/host.key";
      runtimeSource = "${fixture}/host.key";
    }];
  };

  mk = { name, modules, storage, secrets }:
    let
      runtime = evalHost ([
        ./modules/base.nix
        ./modules/marker.nix
        { networking.hostName = name; }
      ] ++ modules);
      # The real extendModules step: the live variant is the host plus the live module,
      # evaluated by the composer's side of the world — never inside a block.
      live = runtime.extendModules { modules = [ ./modules/live.nix ]; };
    in
    {
      inherit name secrets;
      system = "x86_64-linux";
      variants = {
        runtime = extract runtime // { inherit storage; };
        live = extract live;
      };
      install = syntheticInstall;
    };
in
{
  ext4 = mk {
    name = "e2e-ext4";
    modules = [ ./modules/disk-ext4.nix ];
    storage = "ext4";
    secrets = withSecrets;
  };

  memory = mk {
    name = "e2e-memory";
    modules = [ (import ./modules/read-only-store.nix {
      device = "/dev/disk/by-partlabel/nixos";
    }) ];
    storage = "squashfs";
    secrets = noSecrets;
  };

  zfs = mk {
    name = "e2e-zfs";
    modules = [ ./modules/disk-zfs.nix ];
    storage = "zfs";
    secrets = withSecrets;
  };

  plain = mk {
    name = "e2e-plain";
    modules = [ ./modules/disk-ext4.nix ];
    storage = "ext4";
    secrets = noSecrets;
  };
}
