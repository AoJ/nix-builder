{ pkgs }:

# The one privileged place: it assembles the tool set that every block is handed.
# Only tools go in here. A block placed here would let a block reach a block, and
# the rule that keeps the dependency graph acyclic falls.
{
  store = import ./store.nix { inherit pkgs; };
}
