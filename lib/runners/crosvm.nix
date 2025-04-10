{ pkgs
, microvmConfig
, macvtapFds
}:

let
  inherit (pkgs) lib system;
  inherit (microvmConfig)
    vcpu mem balloonMem user interfaces volumes shares socket devices graphics
    kernel initrdPath storeDisk storeOnDisk;
  inherit (microvmConfig.crosvm) pivotRoot extraArgs;

  inherit (macvtapFds) nextFreeFd;
  inherit ((
    builtins.foldl' ({ interfaceFds, nextFreeFd }: { type, id, ... }:
      if type == "tap"
      then {
        interfaceFds = interfaceFds // {
          ${id} = nextFreeFd;
        };
        nextFreeFd = nextFreeFd + 1;
      }
      else if type == "macvtap"
      then { inherit interfaceFds nextFreeFd; }
      else throw "Interface type not supported for crosvm: ${type}"
    ) { interfaceFds = macvtapFds; inherit nextFreeFd; } interfaces
  )) interfaceFds;

  kernelPath = {
    x86_64-linux = "${kernel.dev}/vmlinux";
    aarch64-linux = "${kernel.out}/${pkgs.stdenv.hostPlatform.linux-kernel.target}";
  }.${system};

  gpuParams = {
    context-types = "virgl:virgl2:cross-domain";
    egl = true;
    vulkan = true;
  };

in {

  preStart = ''
    rm -f ${socket}
    ${microvmConfig.preStart}
    ${lib.optionalString (pivotRoot != null) ''
      mkdir -p ${pivotRoot}
    ''}
  '' + lib.optionalString graphics.enable ''
    rm -f ${graphics.socket}
    ${pkgs.crosvm}/bin/crosvm device gpu \
      --socket ${graphics.socket} \
      --wayland-sock $XDG_RUNTIME_DIR/$WAYLAND_DISPLAY\
      --params '${builtins.toJSON gpuParams}' \
      &
    while ! [ -S ${graphics.socket} ]; do
      sleep .1
    done
  '';

  command =
    if user != null
    then throw "crosvm will not change user"
    else lib.escapeShellArgs (
      [
        "${pkgs.crosvm}/bin/crosvm" "run"
        "-m" (toString (mem + balloonMem))
        "-c" (toString vcpu)
        "--serial" "type=stdout,console=true,stdin=true"
        "-p" "console=ttyS0 reboot=k panic=1 ${toString microvmConfig.kernelParams}"
      ]
      ++
      lib.optionals storeOnDisk [
        "-r" storeDisk
      ]
      ++
      lib.optionals graphics.enable [
        "--vhost-user-gpu" graphics.socket
      ]
      ++
      lib.optionals (builtins.compareVersions pkgs.crosvm.version "107.1" < 0) [
        # workarounds
        "--seccomp-log-failures"
      ]
      ++
      lib.optionals (pivotRoot != null) [
        "--pivot-root"
        pivotRoot
      ]
      ++
      lib.optionals (socket != null) [
        "-s" socket
      ]
      ++
      builtins.concatMap ({ image, ... }:
        [ "--rwdisk" image ]
      ) volumes
      ++
      builtins.concatMap ({ proto, tag, source, ... }:
        let
          type = {
            "9p" = "p9";
            "virtiofs" = "fs";
          }.${proto};
        in [
          "--shared-dir" "${source}:${tag}:type=${type}"
        ]
      ) shares
      ++
      (builtins.concatMap ({ id, type, mac, ... }:
        if type == "tap"
        then ["--net" "tap-name=${id},mac=${mac}"]
        else if type == "macvtap"
        then ["--net" "tap-fd=${toString macvtapFds.${id}},mac=${mac}"]
        else throw "Unsupported interface type ${type} for crosvm"
      ) microvmConfig.interfaces)
      ++
      builtins.concatMap ({ bus, path }: {
        pci = [ "--vfio" "/sys/bus/pci/devices/${path},iommu=viommu" ];
        usb = throw "USB passthrough is not supported on crosvm";
      }.${bus}) devices
      ++
      [
        "--initrd" initrdPath
        "${kernelPath}"
      ]
      ++
      extraArgs
    );

  canShutdown = socket != null;

  shutdownCommand =
    if socket != null
    then ''
        ${pkgs.crosvm}/bin/crosvm powerbtn ${socket}
      ''
    else throw "Cannot shutdown without socket";

  setBalloonScript =
    if socket != null
    then ''
      VALUE=$(( $SIZE * 1024 * 1024 ))
      ${pkgs.crosvm}/bin/crosvm balloon $VALUE ${socket}
      SIZE=$( ${pkgs.crosvm}/bin/crosvm balloon_stats ${socket} | \
        ${pkgs.jq}/bin/jq -r .BalloonStats.balloon_actual \
      )
      echo $(( $SIZE / 1024 / 1024 ))
    ''
    else null;

  requiresMacvtapAsFds = true;
}
