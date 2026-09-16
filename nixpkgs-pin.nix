# Everything runs on THIS repo's pinned nixpkgs, resolved from its own flake.lock — never
# on whatever channel the machine happens to carry. Green on any other revision is green
# about a world the consumer does not run.
let
  lock = builtins.fromJSON (builtins.readFile ./flake.lock);
  locked = lock.nodes.nixpkgs.locked;
in
builtins.fetchTarball {
  url = locked.url;
  sha256 = locked.narHash;
}
