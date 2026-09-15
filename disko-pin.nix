# The disko source at the repo's pinned rev (flake.lock), fetched like nixpkgs-pin. The
# ext4 test layout imports disko's NixOS module from here so the host exposes diskoScript /
# mountScript — the same disko the fleet runs, not a floating one.
let
  lock = builtins.fromJSON (builtins.readFile ../../flake.lock);
  d = lock.nodes.disko.locked;
in
builtins.fetchTarball {
  url = "https://github.com/${d.owner}/${d.repo}/archive/${d.rev}.tar.gz";
  sha256 = d.narHash;
}
