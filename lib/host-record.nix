# THE HOST RECORD — what a consumer hands the composer, stated as options.
#
# Every block in here declares its contract as an option interface; the record was the one
# surface that did not, so a missing field surfaced as `attribute 'machine' missing` deep
# in a trace and a typo'd `slotname` silently became a different host. Typed, it answers
# the two questions an example otherwise has to answer in prose: what must be provided,
# and where does each thing come from.
#
# The record is DATA — derivations and strings — never a NixOS configuration. `lib.extract`
# produces the variant halves from an evaluated system; everything else the host states.
#
# Required fields have no default: a host that never reaches an endpoint needing one never
# trips over it (a squashfs appliance has no installer, so it states no `install`).
{ lib }:

let
  inherit (lib) mkOption types;

  machineType = types.submodule {
    options = {
      kernelPackages = mkOption {
        type = types.raw;
        description = "The kernel the target runs — the installer boots the same one.";
      };
      initrdAvailableKernelModules = mkOption { type = types.listOf types.str; default = [ ]; };
      initrdKernelModules = mkOption { type = types.listOf types.str; default = [ ]; };
      kernelModules = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = "Includes the machine's watchdog driver, if it has one.";
      };
      firmware = mkOption { type = types.listOf types.package; default = [ ]; };
    };
  };

  # What `lib.extract` returns for one evaluated system. Paths rather than packages on
  # purpose: the extraction hands over `${toplevel}/kernel`, a store SUBPATH with context.
  variantOptions = {
    toplevel = mkOption {
      type = types.package;
      description = "The system this variant packs.";
    };
    kernel = mkOption { type = types.path; };
    initrd = mkOption { type = types.path; };
    espBinary = mkOption {
      type = types.path;
      description = "The bootloader binary from the TARGET's own systemd — an aarch64 host's aa64 one, never the runner's.";
    };
    kernelParams = mkOption { type = types.listOf types.str; default = [ ]; };
    rootMode = mkOption {
      type = types.enum [ "disk" "memory" ];
      description = "Derived by the extraction: a tmpfs root is what memory-rooted means.";
    };
    machine = mkOption {
      type = types.nullOr machineType;
      default = null;
      description = "Read from the runtime variant only; a live variant carries it unused.";
    };
  };
in
{
  options = {
    name = mkOption {
      type = types.strMatching "[a-z0-9][a-z0-9-]*";
      description = "Names every artifact this host produces, and seeds the iso volume ids.";
    };

    system = mkOption {
      type = types.enum [ "x86_64-linux" "aarch64-linux" ];
      description = "The architecture the host boots on — and the one its installer is built for.";
    };

    slotName = mkOption {
      type = types.strMatching "[a-z0-9][a-z0-9-]*";
      description = ''
        The slot: the partition (or file, per format) phase 2 writes into. The host's ONE
        declaration of it — the storage layout that provides the partition and this field
        must name the same thing, and there is deliberately no default, so a typo fails
        here instead of producing an artifact whose slot nothing can find.
      '';
    };

    layout = mkOption {
      type = types.nullOr types.raw;
      default = null;
      description = ''
        The host's disko layout as DATA ({ disko.devices = …; }), for the format-VM: a zfs
        disk image is formatted from it (a pool is a kernel object, so a runner-arch VM
        makes it), and an ext4 host that declares a layout is too — one layout for runtime,
        image and install. Read from the configuration by the front door; null for a host
        with no disko layout, whose disk formats fall back to userspace assembly.
      '';
    };

    hostId = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = ''
        The target's networking.hostId. A zpool is born with it in the format-VM, so first
        boot imports without -f. Null where the host declares none (an ext4 host).
      '';
    };

    variants = mkOption {
      description = ''
        The same host in the shapes the formats need. Each is `lib.extract` applied to an
        evaluated system: the runtime one, and the live ones built with `extendModules`
        plus a face from `lib.mk`'s `modules` — a live format packs a DIFFERENT toplevel,
        which is why it cannot be derived from the runtime one.
      '';
      type = types.submodule {
        options = {
          runtime = mkOption {
            description = "The host as it runs. What every install installs, and what the disk formats pack.";
            type = types.submodule {
              options = variantOptions // {
                machine = mkOption {
                  type = machineType;
                  description = ''
                    The target machine as the host declares it. The installer is built from
                    it, so it boots exactly where the host boots and carries nothing the
                    host did not claim to need.
                  '';
                };
                storage = mkOption {
                  type = types.enum [ "zfs" "ext4" "squashfs" ];
                  description = ''
                    What the host's root filesystem IS. It decides which endpoints exist:
                    zfs makes the runtime disk images holes (the pool is created by the
                    install, L2), squashfs makes every installer a hole (the image writes
                    that store, L6).
                  '';
                };
              };
            };
          };
          liveNetboot = mkOption {
            description = "The host wearing the netboot face — packed by the kexec and ipxe endpoints.";
            type = types.submodule { options = variantOptions; };
          };
          liveIso = mkOption {
            description = ''
              The host wearing the iso face, as a FUNCTION of the medium's volume label:
              the label is derived by the composer from the artifact's name, so only it can
              supply one.
            '';
            type = types.functionTo (types.submodule { options = variantOptions; });
          };
        };
      };
    };

    secrets = mkOption {
      description = "What lands in the slot. Blocks carries the bytes and never reads them.";
      type = types.submodule {
        options = {
          delivery = mkOption {
            type = types.listOf (types.enum [ "embedded" "sidecar" "deploy" "external" ]);
            description = "How this host gets its secrets; combinable, and empty is valid.";
          };
          files = mkOption {
            default = [ ];
            description = "What lands in the slot (phase 2), and what a sidecar carries.";
            type = types.listOf (types.submodule {
              options = {
                target = mkOption {
                  type = types.strMatching "/.*";
                  description = "Where the file lands INSIDE the slot, never on the host's own filesystem.";
                };
                mode = mkOption {
                  type = types.strMatching "0[0-7][0-7][0-7]";
                  default = "0400";
                  description = "Permissions, where the medium carries them; advisory on vfat.";
                };
                content = mkOption {
                  description = "Where the bytes come from — exactly one of these.";
                  type = types.submodule {
                    options = {
                      text = mkOption {
                        type = types.nullOr types.str;
                        default = null;
                        description = "The bytes, declared in nix — so: already-encrypted material only.";
                      };
                      env = mkOption {
                        type = types.nullOr types.str;
                        default = null;
                        description = "An environment variable, read when the runner runs. Nothing touches the store.";
                      };
                      file = mkOption {
                        type = types.nullOr types.str;
                        default = null;
                        description = "A path, read when the runner runs.";
                      };
                    };
                  };
                };
              };
            });
          };
        };
      };
    };

    install = mkOption {
      default = { };
      description = "What the install needs. Only the `-install` endpoints read it.";
      type = types.submodule {
        options = {
          script = mkOption {
            type = types.nullOr types.package;
            default = null;
            description = ''
              Creates storage no image can hold — a zfs pool — and mounts it at /mnt.
              Declaring one is also what makes this host install through it instead of
              being delivered as its own disk image. Runs under the action's PATH (nix,
              zfs, util-linux, coreutils).
            '';
          };
          payload = mkOption {
            type = types.nullOr types.attrs;
            default = null;
            description = ''
              What is delivered, stated rather than derived. `"closure"` lays the same
              disk out on the target, so the store partition takes the disk actually
              found. An attrset states a payload outright — `{ kind = "image"; image =
              …; }` delivers a finished disk from anywhere, NixOS or not.
            '';
          };
          completion = mkOption {
            type = types.enum [ "reboot" "poweroff" "kexec" ];
            default = "reboot";
            description = ''
              How the machine leaves the install. `kexec` hands straight to what was
              delivered, so a medium left in the machine cannot start the install again.
            '';
          };
          disks = mkOption {
            type = types.nonEmptyListOf types.str;
            description = ''
              The whole disks the target lives on, by stable identity (/dev/disk/by-id/…) —
              the blast radius: cleared every install, and nothing beside them is touched.
            '';
          };
          pool = mkOption {
            type = types.str;
            default = "";
            description = "The zfs pool the act exports before leaving; empty for a plain filesystem.";
          };
          encrypted = mkOption {
            type = types.bool;
            default = false;
            description = "Whether the target pool is encrypted — the layout's own property (L3).";
          };
          report = mkOption {
            type = types.nullOr types.str;
            default = null;
            description = "An executable the installer calls with one line per milestone.";
          };
        };
      };
    };
  };
}
