{ lib, config, pkgs, tools, ... }:

let
  inherit (lib) mkOption types;
in
{
  options = {
    name = mkOption { type = types.strMatching "[a-z0-9][a-z0-9-]*"; };

    files = mkOption {
      type = types.listOf (types.submodule {
        options = {
          target = mkOption { type = types.strMatching "/.*"; };
          source = mkOption { type = types.path; };
        };
      });
    };

    medium = mkOption {
      type = types.enum [ "vfat" "iso" "json" ];
      description = "How the consumer takes the data. Mounting is one way of taking it.";
    };

    out = mkOption {
      readOnly = true;
      type = types.submodule {
        options = {
          file = mkOption { type = types.package; };
          fs = mkOption { type = types.str; };
        };
      };
    };
  };

  config.out =
    let
      staged = lib.concatMapStringsSep "\n" (f: ''
        mkdir -p "$staged$(dirname ${lib.escapeShellArg f.target})"
        cp ${f.source} "$staged"${lib.escapeShellArg f.target}
      '') config.files;

      vfat = pkgs.runCommand "${config.name}-sidecar.img"
        { nativeBuildInputs = [ pkgs.dosfstools pkgs.mtools pkgs.coreutils pkgs.findutils ]; }
        ''
          set -euo pipefail
          staged="$(mktemp -d)"
          ${staged}
          truncate -s 4M "$out"
          mkfs.fat -n SECRETS -i ${lib.escapeShellArg (tools.ids.volumeId "${config.name}:sidecar")} "$out"
          (cd "$staged" && find . -mindepth 1 -type d -printf '%P\n' | sort \
            | while IFS= read -r d; do mmd -i "$out" "::/$d"; done)
          (cd "$staged" && find . -mindepth 1 -type f -printf '%P\n' | sort \
            | while IFS= read -r f; do mcopy -i "$out" "$f" "::/$f"; done)
        '';

      isoFile = pkgs.runCommand "${config.name}-sidecar.iso"
        { nativeBuildInputs = [ pkgs.xorriso pkgs.coreutils ]; }
        ''
          set -euo pipefail
          staged="$(mktemp -d)"
          ${staged}
          xorriso -as mkisofs -r -J \
            -volid ${lib.escapeShellArg (lib.toUpper (tools.ids.volumeId "${config.name}:sidecar"))} \
            -o "$out" "$staged"
        '';
      # A medium the consumer READS, not mounts: one object, target path → base64 content.
      # Base64 because a secret is bytes, and json only carries text.
      json = pkgs.runCommand "${config.name}-sidecar.json"
        { nativeBuildInputs = [ pkgs.jq pkgs.coreutils ]; }
        ''
          set -euo pipefail
          {
            ${lib.concatMapStringsSep "\n" (f: ''
              jq -n --arg t ${lib.escapeShellArg f.target} \
                --arg c "$(base64 -w0 < ${f.source})" '{ key: $t, value: $c }'
            '') config.files}
          } | jq -s -S from_entries > "$out"
        '';
    in
    {
      file = { vfat = vfat; iso = isoFile; json = json; }.${config.medium};
      fs = { vfat = "vfat"; iso = "iso9660"; json = "json"; }.${config.medium};
    };
}
