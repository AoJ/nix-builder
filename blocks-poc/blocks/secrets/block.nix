{ lib, config, pkgs, tools, ... }:

let
  inherit (lib) mkOption types;
in
{
  options = {
    name = mkOption { type = types.strMatching "[a-z0-9][a-z0-9-]*"; };

    files = mkOption {
      # Paths as STRINGS, resolved when the runner runs: a secret in a derivation is a
      # secret in the store, and a sidecar exists to carry secrets.
      type = types.listOf (types.submodule {
        options = {
          target = mkOption { type = types.strMatching "/.*"; };
          source = mkOption { type = types.str; };
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
          # A tool taking the destination as its argument, not a derivation — see files.
          run = mkOption { type = types.package; };
          fs = mkOption { type = types.str; };
        };
      };
    };
  };

  config.out =
    let
      manifest = pkgs.writeText "${config.name}-sidecar-manifest"
        (lib.concatMapStrings (f: "${f.source}\t${f.target}\n") config.files);

      volumeId = tools.ids.volumeId "${config.name}:sidecar";

      runner = script: vars: runtimeInputs: tools.bashTool {
        name = "sidecar-${config.name}";
        inherit runtimeInputs;
        text = vars + builtins.readFile script;
      };

      byMedium = {
        vfat = runner ./sidecar-vfat.sh ''
          fat_image=${lib.getExe tools.fatImageApp}
          label=SECRETS
          volume_id=${lib.escapeShellArg volumeId}
          size_bytes=${toString (4 * 1048576)}
          manifest=${manifest}
        '' [ pkgs.coreutils ];

        iso = runner ./sidecar-iso.sh ''
          volume_id=${lib.escapeShellArg (lib.toUpper volumeId)}
          manifest=${manifest}
        '' [ pkgs.coreutils pkgs.xorriso ];

        json = runner ./sidecar-json.sh ''
          manifest=${manifest}
        '' [ pkgs.coreutils pkgs.jq ];
      };
    in
    {
      run = byMedium.${config.medium};
      fs = { vfat = "vfat"; iso = "iso9660"; json = "json"; }.${config.medium};
    };
}
