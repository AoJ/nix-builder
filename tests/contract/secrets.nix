{ pkgs, tools }:

let
  inherit (pkgs) lib;
  secrets = import ../../blocks/secrets/default.nix { inherit pkgs tools; };

  fixture = pkgs.writeText "secret-fixture" "SOME-SECRET-FIXTURE";
  files = [ { target = "/sops.age"; content.file = "${fixture}"; } ];

  runFor = args: lib.getExe (secrets ({ inherit files; } // args)).run;
  asVfat = runFor { name = "fixture"; sidecarFormat = "vfat"; };
  asIso = runFor { name = "fixture"; sidecarFormat = "iso"; };
  asJson = runFor { name = "fixture"; sidecarFormat = "json"; };
  elsewhere = runFor { name = "other"; sidecarFormat = "vfat"; };
  # The same three content forms the slot takes: a sidecar is the other carrier of the
  # same declaration.
  everyForm = lib.getExe (secrets {
    name = "forms";
    sidecarFormat = "json";
    files = [
      { target = "/from-file"; content.file = "${fixture}"; }
      { target = "/from-text"; content.text = "declared in nix\n"; }
      { target = "/from-env"; content.env = "FIXTURE_SECRET"; }
    ];
  }).run;
in
pkgs.runCommand "test-secrets"
  { nativeBuildInputs = [ pkgs.mtools pkgs.xorriso pkgs.file pkgs.coreutils pkgs.jq ]; }
  ''
    set -euo pipefail

    echo "== a runner, not a derivation: nothing lands in a store path =="
    ${asVfat} side.img
    ${asIso} side.iso
    ${asJson} side.json

    echo "== the consumer finds the file where it was declared, in every sidecar format =="
    mcopy -i side.img ::/sops.age got-vfat
    cmp got-vfat ${fixture}
    xorriso -osirrox on -indev side.iso -extract /sops.age got-iso 2>/dev/null
    cmp got-iso ${fixture}
    jq -r '."/sops.age"' side.json | base64 -d > got-json
    cmp got-json ${fixture}

    echo "== the declared fs is the real one — read it off the artifact =="
    file -b side.img | grep -qi 'fat'
    file -b side.iso | grep -qi 'iso 9660'

    echo "== run twice, byte for byte the same =="
    ${asVfat} again.img && cmp side.img again.img
    ${asIso} again.iso && cmp side.iso again.iso
    ${asJson} again.json && cmp side.json again.json

    echo "== every content form reaches a sidecar, env read at RUN time =="
    FIXTURE_SECRET='from the environment' ${everyForm} forms.json
    jq -r '."/from-file"' forms.json | base64 -d | cmp - ${fixture}
    jq -r '."/from-text"' forms.json | base64 -d | cmp - <(printf 'declared in nix\n')
    jq -r '."/from-env"' forms.json | base64 -d | cmp - <(printf 'from the environment')

    echo "== refusal: an unset variable, and nothing was written =="
    ! ${everyForm} never.json 2> refusal-env.log
    grep -q 'carries no FIXTURE_SECRET' refusal-env.log
    [ ! -e never.json ]

    echo "== two names, two identities =="
    mine="$(file -b side.img | grep -o 'serial number 0x[0-9a-f]*')"
    ${elsewhere} other.img
    theirs="$(file -b other.img | grep -o 'serial number 0x[0-9a-f]*')"
    [ -n "$mine" ] && [ "$mine" != "$theirs" ]

    touch $out
  ''
