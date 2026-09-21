# Copy this directory into your own repository and adapt host.nix — it needs nothing
# from the builder's source tree.
{
  description = "An encrypted-zfs host, installed by the blocks factory.";

  inputs = {
    nixpkgs.url = "https://flakehub.com/f/NixOS/nixpkgs/0.2605.*.tar.gz";
    builder.url = "github:AoJ/nix-builder";
    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, builder, disko }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs { inherit system; };
      endpoints = import ./host.nix {
        inherit pkgs builder;
        diskoModule = disko.nixosModules.disko;
      };
    in
    {
      # An encrypted pool is created at install with the real passphrase (L3): no runtime
      # image is ever encrypted, so this host's deliverables are its installers.
      packages.${system} = {
        default = endpoints.image-kexec-install.file;
        usb = endpoints.image-raw-install.file;
      };

      # The artifact is inert until phase 2 puts the host key AND the pool passphrase in
      # its slot; an installer started without the passphrase refuses before any wipe:
      #   nix build .#default
      #   nix run .#personalize-kexec -- ./result-tree
      apps.${system}.personalize-kexec = {
        type = "app";
        program = pkgs.lib.getExe endpoints.image-personalize-kexec.run;
      };
    };
}
