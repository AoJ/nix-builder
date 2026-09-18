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
        readOnlyStore = { device }:
          import ../modules/read-only-store.nix { inherit (tools) roStore; inherit device; };
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

  # Paths blocks OWNS and publishes, so a host reads them from here instead of hardcoding
  # a string both sides have to keep guessing right. They are ours, inside our own
  # environment — what happens on the host's own filesystem is the host's to name.
  paths = {
    # Where the install action lays the slot's files out while it runs, for a host's own
    # storage scripts to read (a pool passphrase, say — blocks never learns which file is
    # which).
    installSlot = "/run/slot";
  };

  # An evaluated nixosSystem in, the variant data a host record carries out. The front
  # door calls it for you; it is here for a consumer assembling a record by hand.
  extract = import ./extract.nix;

  # The host record's option interface — what the front door fills in, stated as options
  # with descriptions. `compose` validates every record through it; read it as the
  # contract between the thing that knows a host and the blocks, which never see one.
  hostRecord = import ./host-record.nix;
}
