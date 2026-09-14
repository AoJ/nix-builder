{ lib, config, pkgs, tools, ... }:

let
  inherit (lib) mkOption types;

  # The installing OS is the BLOCK's, not the caller's: the caller hands over what to install
  # and how to place it, never what installs it. Synthetic here — the shape is the point.
  installerKernel = pkgs.writeText "installer-kernel" "the installer OS's kernel";
  installerInitrd = pkgs.writeText "installer-initrd" "the installer OS's initrd";
in
{
  options = {
    name = mkOption { type = types.strMatching "[a-z0-9][a-z0-9-]*"; };

    toplevel = mkOption {
      type = types.package;
      description = "The system to be installed.";
    };

    closure = mkOption {
      type = types.listOf types.package;
      description = "What the installer carries, so it can install offline.";
    };

    prepare = mkOption {
      type = types.package;
      description = "Brings the target's storage into existence. The block does not know its shape.";
    };

    mount = mkOption {
      type = types.package;
      description = "Mounts that storage where the install writes.";
    };

    keyDestination = mkOption {
      type = types.str;
      description = "Where the installed system's key lands, once the target exists.";
    };

    out = mkOption {
      readOnly = true;
      type = types.submodule {
        options = {
          # The installer, in the extracted shape image consumes. It goes to image, which
          # does not know it is one.
          system = mkOption {
            type = types.submodule {
              options = {
                toplevel = mkOption { type = types.package; };
                kernel = mkOption { type = types.package; };
                initrd = mkOption { type = types.package; };
                kernelParams = mkOption { type = types.listOf types.str; };
                storePaths = mkOption { type = types.listOf types.package; };
              };
            };
          };
        };
      };
    };
  };

  config.out.system =
    let
      run = tools.bashTool {
        name = "install-${config.name}";
        runtimeInputs = [ pkgs.coreutils ];
        text = ''
          prepare=${config.prepare}
          mount_cmd=${config.mount}
          toplevel=${config.toplevel}
          key_destination=${lib.escapeShellArg config.keyDestination}
        '' + builtins.readFile ./install.sh;
      };
    in
    {
      toplevel = run;
      kernel = installerKernel;
      initrd = installerInitrd;
      kernelParams = [ "installer=${config.name}" ];
      storePaths = [ run ] ++ config.closure;
    };
}
