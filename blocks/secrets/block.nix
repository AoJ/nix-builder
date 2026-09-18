{ lib, config, pkgs, tools, ... }:

let
  inherit (lib) mkOption types;
in
{
  options = {
    name = mkOption { type = types.strMatching "[a-z0-9][a-z0-9-]*"; };

    files = mkOption {
      # What goes where, and where the bytes come from — never what they are. `text` is
      # already in the store by the time it gets here; `env` and `file` are resolved when
      # the runner runs, because a secret in a derivation is a secret in the store.
      type = types.listOf (types.submodule {
        options = {
          target = mkOption { type = types.strMatching "/.*"; };
          mode = mkOption { type = types.strMatching "0[0-7][0-7][0-7]"; default = "0400"; };
          content = mkOption {
            type = types.submodule {
              options = {
                text = mkOption { type = types.nullOr types.str; default = null; };
                env = mkOption { type = types.nullOr types.str; default = null; };
                file = mkOption { type = types.nullOr types.str; default = null; };
              };
            };
          };
        };
      });
    };

    sidecarFormat = mkOption {
      type = types.enum [ "vfat" "iso" "json" ];
      description = "The form the consumer takes the sidecar in: a filesystem it mounts, or a format it reads.";
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
      manifest = tools.secretManifest { inherit (config) name files; };

      volumeId = tools.ids.volumeId "${config.name}:sidecar";

      runner = script: vars: runtimeInputs: tools.bashTool {
        name = "sidecar-${config.name}";
        inherit runtimeInputs;
        text = vars
          + builtins.readFile tools.secretResolve
          + builtins.readFile script;
      };

      byFormat = {
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
      run = byFormat.${config.sidecarFormat};
      fs = { vfat = "vfat"; iso = "iso9660"; json = "json"; }.${config.sidecarFormat};
    };
}
