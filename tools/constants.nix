# Pure constants shared across the tool / block / api layers — no pkgs, so any layer imports
# them directly. Each is a value that BOTH a producer and a consumer must agree on; living
# here ONCE is what turns "two sides must match" into a single source instead of two literals
# that drift silently (an unbootable host, an install that cannot find its key).
{
  # The fixed partition labels userspace assembly stamps. A disko-owned disk labels its own
  # partitions (read from the layout); this is only the assembly path.
  diskLabels = { esp = "ESP"; store = "nixos"; };

  # Where the install action lays the slot's files out while it runs: the action and the
  # installer PUT them here, the host's own storage scripts READ from here. Published to
  # hosts as builder.lib.paths.installSlot.
  installSlot = "/run/slot";

  # The nixpkgs name the store squashfs rides under inside an initrd / iso: the image writes
  # it there, the netboot and iso faces mount it from there. Shared with nixpkgs' own units.
  storeFileName = "nix-store.squashfs";

  # The nixpkgs path the closure's registration dump sits at: the image writes it into the
  # store, the boot-time register unit loads the DB from it. Shared with nixpkgs.
  registrationPath = "/nix/store/nix-path-registration";
}
