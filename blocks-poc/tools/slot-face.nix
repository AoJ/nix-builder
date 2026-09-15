# Where a slot lives, per format — the two-faces table as a function. `name` is the slot's
# name (its partlabel, and the basename of its file); the format decides the shape. The
# image block builds from this and the runtime consumers read from it, so the location has
# ONE source instead of a path restated in the marker and the installer.
{ format, name }:
{
  iso   = { path = "/boot/${name}.img"; mount = "/iso"; };
  raw   = { partlabel = name; };
  qcow2 = { partlabel = name; };
  kexec = { dir = "/run/initrd-slot"; };
  ipxe  = { dir = "/run/initrd-slot"; };
}.${format}
