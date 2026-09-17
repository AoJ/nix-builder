# The public API, in ONE place: the flake exports it and the examples' gate consumes it
# through the same value, so what the suite proves is exactly what a consumer gets.
{
  # Hand in a pkgs, get everything that composes a host.
  mk = { pkgs }: rec {
    tools = import ../tools { inherit pkgs; };

    # A host record in, the full endpoint set out.
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
  };

  # An evaluated nixosSystem in, the variant data a host record carries out.
  extract = import ./extract.nix;
}
