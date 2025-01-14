# Shares

In `microvm.shares` elements the `proto` field allows either of two
values:

- `9p` (default) is built into many hypervisors, allowing you to
  quickly share a directory tree

- `virtiofs` requires a separate virtiofsd service which is only
  started as a prerequisite when you start MicroVMs through a systemd
  service that comes with the `microvm.nixosModules.host` module.

  Expect `virtiofs` to yield better performance over `9p`.

## Sharing a host's `/nix/store`

If a share with `source = "/nix/store"` is defined, size and build
time of the stage1 squashfs for `/dev/vda` will be reduced
drastically.

```nix
microvm.shares = [ {
  tag = "ro-store";
  source = "/nix/store";
  mountPoint = "/nix/.ro-store";
} ];
```

## Writable `/nix/store` overlay

An optional writable layer will be mounted if the path
`microvm.writableStoreOverlay` is set. Make sure that the path is
located on a writable filesystem.

**Caveat:** The Linux overlay filesystem is very picky about the
filesystems that can be the upper (writable) layer. 9p/virtiofs shares
don't work currently, so resort to using a volume for that:

```
{ config, ... }:
{
  microvm.writableStoreOverlay = "/nix/.rw-store";

  microvm.volumes = [ {
    image = "nix-store-overlay.img";
    mountPoint = config.microvm.writableStoreOverlay;
    size = 2048;
  } ];
}
```

**Caveat:** The Nix database will forget all built packages after a
reboot, containing only what is needed for the VM's NixOS
system. Until this has been solved, it is recommended to just delete
and recreate the overlay after MicroVM shutdown or before startup.
