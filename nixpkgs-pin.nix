# The PoC runs on the REPO's pinned nixpkgs, resolved from flake.lock — never on whatever
# channel this machine happens to carry. Green on any other revision is green about a world
# the fleet does not run.
let
  lock = builtins.fromJSON (builtins.readFile ../../flake.lock);
  locked = lock.nodes.nixpkgs.locked;
in
builtins.fetchTarball {
  url = locked.url;
  sha256 = locked.narHash;
}
