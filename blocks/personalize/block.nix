{ lib, config, pkgs, tools, ... }:

let
  inherit (lib) mkOption types;
in
{
  options = {
    name = mkOption { type = types.strMatching "[a-z0-9][a-z0-9-]*"; };

    slot = mkOption {
      type = types.attrsOf types.str;
      description = "The artifact face, as image declared it built. Verified against the artifact.";
    };

    files = mkOption {
      # What goes where, and where the bytes come from. The block places them and never
      # reads them: what a secret IS, and what it is for, is the host's business.
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

    out = mkOption {
      readOnly = true;
      type = types.submodule {
        options = {
          # A tool taking the artifact as its argument, not a derivation — this phase
          # must not be cached.
          run = mkOption { type = types.package; };
        };
      };
    };
  };

  config.out.run =
    let
      manifest = tools.secretManifest { inherit (config) name files; };

      runner = script: vars: runtimeInputs: tools.bashTool {
        name = "personalize-${config.name}";
        runtimeInputs = runtimeInputs ++ [ pkgs.coreutils ];
        text = vars
          + builtins.readFile tools.secretResolve
          + builtins.readFile script;
      };
    in
    {
      partition = runner ./partition.sh ''
        slot_name=${lib.escapeShellArg config.slot.name}
        manifest=${manifest}
      '' [ pkgs.gawk pkgs.gptfdisk pkgs.mtools pkgs.diffutils ];

      file = runner ./file.sh ''
        slot_path=${lib.escapeShellArg config.slot.path}
        manifest=${manifest}
      '' [ pkgs.gawk pkgs.xorriso pkgs.mtools pkgs.diffutils ];

      initrd-append = runner ./initrd-append.sh ''
        slot_name=${lib.escapeShellArg config.slot.name}
        manifest=${manifest}
      '' [ pkgs.findutils pkgs.cpio ];
    }.${config.slot.destination};
}
