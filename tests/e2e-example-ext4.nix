# Booting the EXAMPLE a user copies — not a parallel test host, the very examples/ext4 host,
# with only the witness modules threaded through its extraModules seam. It proves what the
# examples/ gate (eval-only) never could: the example's produced image BOOTS, its userspace
# comes up, and the embedded slot its config mounts is really there and mountable. The example
# is a thing to USE; this is where "it boots" stops being a claim it makes about itself.
{ pkgs }:

let
  boot = import ./lib-boot.nix { inherit pkgs; };
  record = import ./e2e-record.nix { inherit pkgs; };
  builder = { lib = import ../lib/api.nix; };
  diskoModule = (import ../disko-pin.nix) + "/module.nix";

  # Witness the EXAMPLE's OWN mount (the marker mounts the partition its own way; this checks
  # the fileSystems entry the example config actually declared), before the marker powers off.
  verifyMount = { pkgs, ... }: {
    systemd.services.e2e-example-slot = {
      wantedBy = [ "multi-user.target" ];
      before = [ "e2e-marker.service" ];
      serviceConfig.Type = "oneshot";
      path = [ record pkgs.util-linux ];
      script = ''
        if mountpoint -q /run/secrets; then
          e2e-record "E2E-EXAMPLE-SLOT-MOUNTED"
        else
          e2e-record "E2E-EXAMPLE-SLOT-UNMOUNTED"
        fi
      '';
    };
  };

  endpoints = import ../examples/ext4/host.nix {
    inherit pkgs builder diskoModule;
    extraModules = [
      (import ./hosts/modules/e2e-result.nix { inherit record; })
      (import ./hosts/modules/marker.nix { inherit record; })
      verifyMount
    ];
  };
in
{
  witnesses = [ ];
  check = boot {
    name = "e2e-example-ext4";
    image = endpoints.image-raw.file;
    expect = ''
      grep -q "E2E-BOOT-OK example-ext4" result
      grep -q "E2E-EXAMPLE-SLOT-MOUNTED" result
      grep -q "E2E-KEY-EMPTY" result
    '';
  };
}
