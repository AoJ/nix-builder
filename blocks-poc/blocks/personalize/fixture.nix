# A fixture sops bundle encrypted to a throwaway key, so a test can hold a key that opens
# what it is testing — nobody can personalize a real host's artifact, and this is the
# smallest substitution that keeps the whole chain real.
{ pkgs }:

pkgs.runCommand "sops-fixture" { nativeBuildInputs = [ pkgs.age pkgs.sops ]; }
  ''
    set -euo pipefail
    export HOME="$TMPDIR"
    mkdir -p "$out"
    age-keygen -o "$out/host.key" 2>/dev/null
    age-keygen -o "$out/other.key" 2>/dev/null
    pub="$(age-keygen -y "$out/host.key")"

    printf 'identity: fixture\n' > s.yaml
    sops --encrypt --age "$pub" s.yaml > "$out/bundle.yaml"
    printf '{ "identity": "fixture" }\n' > s.json
    sops --encrypt --age "$pub" s.json > "$out/bundle.json"
    sops --encrypt --age "$(age-keygen -y "$out/other.key")" s.yaml \
      > "$out/bundle-foreign.yaml"
    printf 'not a bundle\n' > "$out/garbage"
  ''
