# The public API, in ONE place: the flake exports it and the examples' gate consumes it
# through the same value, so what the suite proves is exactly what a consumer gets.
rec {
  # Hand in a pkgs, get everything that composes a host.
  mk = { pkgs }:
    let
      inherit (pkgs) lib;
      tools = import ../tools { inherit pkgs; };
      compose = import ../compose.nix { inherit pkgs tools; };

      # The modules a consumer needs on the host side: each live variant is the host plus
      # a face (extendModules), and a memory-rooted host declares its read-only store.
      # They carry the host-context half a face cannot know — no disk mounts, no
      # bootloader to install, so no initrd secrets either.
      modules = {
        liveNetboot = import ../modules/live-netboot.nix { face = tools.netbootFace; };
        liveIso = label: import ../modules/live-iso.nix { inherit label; face = tools.isoFace; };
        readOnlyStore = { device ? null }:
          import ../modules/read-only-store.nix ({
            inherit (tools) roStore;
            storeLabel = tools.diskLabels.store;
          } // lib.optionalAttrs (device != null) { inherit device; });
        inherit diskLayout diskLayoutZfs;
      };

      front = import ./images-for.nix {
        inherit lib compose modules;
        extract = import ./extract.nix;
      };
    in
    {
      inherit tools compose modules;
      inherit (front) imagesFor recordFor;
    };

  # The front door, without assembling `mk` first: an evaluated NixOS system plus what a
  # configuration cannot know, and every endpoint comes back.
  imagesFor = { pkgs, ... }@args:
    (mk { inherit pkgs; }).imagesFor (removeAttrs args [ "pkgs" ]);

  # The record `imagesFor` would compose, for a consumer who wants to adjust one field
  # before composing it themselves.
  recordFor = { pkgs, ... }@args:
    (mk { inherit pkgs; }).recordFor (removeAttrs args [ "pkgs" ]);

  # Turn the endpoint set into flake outputs UNIFORMLY — no host hand-lists which endpoints
  # it has, and NOTHING is filtered out. Every host runs the same split by KIND: the images
  # become `packages` (a law-forbidden one among them is a derivation that fails to build
  # with its law — present in the set, listed by `nix flake show`, refused only when built),
  # the runners become `apps`. Splitting by kind, never by whether a pair is allowed, is
  # what keeps every host's set identical and a wrong build loud instead of a missing name.
  deliverables = { pkgs, endpoints }:
    let inherit (pkgs) lib; in
    {
      packages = lib.mapAttrs (_: e: e.file)
        (lib.filterAttrs (_: e: e ? file) endpoints);
      apps = lib.mapAttrs (_: e: { type = "app"; program = lib.getExe e.run; })
        (lib.filterAttrs (_: e: e ? run) endpoints);
    };

  # Paths blocks OWNS and publishes, so a host reads them from here instead of hardcoding
  # a string both sides have to keep guessing right. They are ours, inside our own
  # environment — what happens on the host's own filesystem is the host's to name.
  paths = {
    # Where the install action lays the slot's files out while it runs, for a host's own
    # storage scripts to read (a pool passphrase, say — blocks never learns which file is
    # which). From the ONE constant the install action and installer also read, so what a
    # host points its keylocation at is exactly where the slot is laid.
    inherit (import ../tools/constants.nix) installSlot;
  };

  # The identity a host must know AHEAD of the build to mount by: a secrets sidecar's label,
  # a slot's volume id. Pure functions of the host's name — the SAME ones the blocks stamp
  # the media with — so a host configuration derives EXACTLY what the artifact will carry and
  # the two cannot drift. No pkgs: it is a hash of a name.
  #   fileSystems."/secrets".device = "/dev/disk/by-label/${builder.lib.labels.secretsIsoLabel name}";
  labels = let ids = import ../tools/ids.nix; in {
    inherit (ids) secretsVolumeId secretsIsoLabel secretsVfatLabel slotVolumeId;
  };

  # The disk layout template: a disko layout for a host that must own a disk but has
  # nothing particular to say about it. Imported in the host's OWN configuration (next to
  # disko's module, which the host brings), so every choice in it is visible there and
  # overridden like any other option. It takes no pkgs — it is plain disko data.
  diskLayout = import ../modules/disk-layout.nix;

  # The zfs variant of the template: the same disk shape with the rest one pool, and
  # optional L3 encryption as data. Same story as diskLayout — plain disko data, imported
  # in the host's own configuration next to disko's module.
  diskLayoutZfs = import ../modules/disk-layout-zfs.nix;

  # An evaluated nixosSystem in, the variant data a host record carries out. The front
  # door calls it for you; it is here for a consumer assembling a record by hand.
  extract = import ./extract.nix;

  # The host record's option interface — what the front door fills in, stated as options
  # with descriptions. `compose` validates every record through it; read it as the
  # contract between the thing that knows a host and the blocks, which never see one.
  hostRecord = import ./host-record.nix;
}
