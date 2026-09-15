# The seam between the repo's typed host schema and the dimensions — one direction only:
# today's fields in, the vocabulary out. A pair of old values that does not go together is
# REFUSED at eval, never guessed around: that is one host failing on its own declaration,
# which is the distinction the whole design rests on.
#
# profileModules { live } appears nowhere here on purpose: it is the flag the dimensions
# exist to kill, and it is a call-site argument today, not host data — it dies with the old
# image path.
{ lib }:

let
  refuse = host: why: throw "schema(${host.name or "?"}): ${why}";
in
{
  dimensions = host:
    let
      r = host.realization or { };
      boot = r.boot or null;
      medium = r.root.medium or null;

      # realization.root.medium mixes WHERE the root lives with WHICH filesystem it is;
      # the split is the first row of the design's replacement table.
      runtime =
        if medium == "zfs" then { mode = "disk"; storage = "zfs"; }
        else if medium == "ext4" then { mode = "disk"; storage = "ext4"; }
        else if medium == "tmpfs" then { mode = "memory"; storage = "squashfs"; }
        else refuse host "realization.root.medium=${toString medium} maps to no dimension";

      checked =
        if boot == "ram" && runtime.mode == "disk"
        then refuse host "boot=ram contradicts root.medium=${toString medium}"
        else if boot == "disk" && runtime.mode == "memory"
        then refuse host "boot=disk contradicts root.medium=tmpfs"
        else runtime;

      # secretsTransport.kind mixed location with delivery; "sops" was a bundle format,
      # never a transport. Each old kind names exactly one delivery.
      deliveryOf = {
        sops-boot = "deploy";
        creds-cd = "sidecar";
        baked-partition = "embedded";
      };
      kind = r.secretsTransport.kind or null;
      delivery =
        if kind == null
        then [ ]
        else [
          (deliveryOf.${kind} or (refuse host "secretsTransport.kind=${kind} maps to no delivery"))
        ];

      # delivery.modes named OPERATIONS; what survives is which endpoints the host's
      # operations consume — the producer side of "a declared delivery must have a
      # producer", and the coverage table's required rows.
      endpointOf = {
        image = [ "image-raw" "image-qcow2" ];
        deploy-install = [ "image-kexec-install" ];
        iso-swap = [ "image-iso" ];
        colmena = [ ];
      };
      endpoints = lib.unique (lib.concatMap
        (m: endpointOf.${m} or (refuse host "delivery.modes contains unknown ${m}"))
        (r.delivery.modes or [ ]));
    in
    {
      runtime = checked;
      secrets.delivery = delivery;
      install = {
        pool = r.root.pool or null;
        # L3: encryption is a property of the storage layout and follows the install.
        encrypted = r.root.encryption or false;
      };
      endpointsRequired = endpoints;
    };
}
