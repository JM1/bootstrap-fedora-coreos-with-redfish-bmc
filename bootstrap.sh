#!/bin/bash
# vim:set tabstop=8 shiftwidth=4 expandtab:
# kate: space-indent on; indent-width 4;
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (c) 2023 Jakob Meng, <jakobmeng@web.de>

set -euxo pipefail

BMC_HOSTNAME_PORT=${BMC_HOSTNAME_PORT:-}
ENDPOINT=${ENDPOINT:-}
INSTALL_DEVICE=${INSTALL_DEVICE:?missing install device such as /dev/sda or /dev/nvme0n1}

error() {
    echo "ERROR: $*" 1>&2
}

warn() {
    echo "WARNING: $*" 1>&2
}

if command -v docker >/dev/null 2>&1; then
    engine=docker
elif command -v podman >/dev/null 2>&1; then
    engine=podman
else
    error "Docker and Podman not found"
    exit 125
fi

if [ "$(id -u)" -ne 0 ]; then
    if [ "$engine" = "podman" ] || ! id -nGz | tr '\0' '\n' | grep -q '^docker$'; then
        error "Please run as root"
        exit 125
    fi
fi

cmd="$(readlink -f "$0")"
cd "$(dirname "$cmd")"

if ! "$engine" inspect "bootstrap-httpd:rawhide" >/dev/null 2>&1; then
    "$engine" build -t "bootstrap-httpd:rawhide" .
fi

if [ -z "$("$engine" volume ls -q '--filter=name=^bootstrap-storage$')" ]; then
    "$engine" volume create bootstrap-storage
fi

bootstrap_storage="$("$engine" volume inspect bootstrap-storage --format '{{ .Mountpoint }}')"

# always update to latest image
"$engine" pull quay.io/coreos/coreos-installer:release

"$engine" run --rm -v bootstrap-storage:/data -w /data \
    quay.io/coreos/coreos-installer:release \
    download -f iso --fetch-retries 3

rootfs_url=$(curl -s -L https://builds.coreos.fedoraproject.org/streams/stable.json \
            | jq -r '.architectures.x86_64.artifacts.metal.formats.pxe.rootfs.location')

if [ ! -e "$bootstrap_storage/config.ign" ] || [ "config.bu" -nt "$bootstrap_storage/config.ign" ]; then
    "$engine" run -i --rm quay.io/coreos/butane:release --pretty --strict \
        < "config.bu" > "$bootstrap_storage/config.ign"
fi

last_coreos_iso=$(cd "$bootstrap_storage" && compgen -G "fedora-coreos-*-live.*.iso" | grep -v '.sig$' | sort | tail -n 1)

if [ ! -e "$bootstrap_storage/bootstrap-minimal.iso" ] \
   || [ "$cmd" -nt "$bootstrap_storage/bootstrap-minimal.iso" ] \
   || [ "$bootstrap_storage/$last_coreos_iso" -nt "$bootstrap_storage/bootstrap-minimal.iso" ] \
   || [ "$bootstrap_storage/config.ign" -nt "$bootstrap_storage/bootstrap-minimal.iso" ]; then
    rm -f "$bootstrap_storage/bootstrap-minimal.iso"

    # Do not use '--rootfs-url' option of 'coreos-installer iso extract minimal-iso' because it will
    # be overwritten by any '--live-karg-append' option passed to 'coreos-installer iso customize'.
    "$engine" run --rm -v bootstrap-storage:/data -w /data \
        quay.io/coreos/coreos-installer:release \
        iso extract minimal-iso \
            "$last_coreos_iso" "bootstrap-minimal.iso"
    chmod u=rw,g=r,o=r "$bootstrap_storage/bootstrap-minimal.iso"

    # IPv6 is disabled because system might not provide internet connectivity with IPv6
    "$engine" run --rm -v bootstrap-storage:/data -w /data \
        quay.io/coreos/coreos-installer:release \
        iso customize --force \
            --dest-device "$INSTALL_DEVICE" \
            --dest-ignition "config.ign" \
            --live-karg-append "coreos.live.rootfs_url=$rootfs_url" \
            --live-karg-append console=tty0 \
            --live-karg-append console=ttyS0,115200 \
            --live-karg-append earlyprintk=ttyS0,115200 \
            --live-karg-append net.ifname-policy=mac \
            --live-karg-append ipv6.disable=1 \
            --dest-karg-append console=tty0 \
            --dest-karg-append console=ttyS0,115200 \
            --dest-karg-append earlyprintk=ttyS0,115200 \
            --dest-karg-append net.ifname-policy=mac \
            --dest-karg-append ipv6.disable=1 \
            "bootstrap-minimal.iso"
fi

if [ -n "$("$engine" container ls -a -q '--filter=name=^bootstrap-httpd$')" ]; then
    # Container exists
    if [ -z "$("$engine" container ls -a -q '--filter=name=^bootstrap-httpd$' --filter=status=running)" ]; then
        warn "Stopped container will be (re)started, but not rebuild. Remove container first to force rebuild."
        "$engine" start bootstrap-httpd
    fi
    # Container is running
else
    # Container does not exist
    "$engine" run \
        --detach \
        --name bootstrap-httpd \
        --cap-add=NET_ADMIN \
        --security-opt no-new-privileges \
        --init \
        --network=bridge \
        -p 80:80 \
        -p 443:443 \
        -v "$PWD/etc/httpd/conf.d/coreos-installer.conf:/etc/httpd/conf.d/coreos-installer.conf:ro" \
        -v "$PWD/etc/httpd/conf.d/welcome.conf:/etc/httpd/conf.d/welcome.conf:ro" \
        -v 'bootstrap-storage:/var/www/coreos-installer/:ro' \
        bootstrap-httpd:rawhide
        # uid and gid of files and directories should be 0
fi

if [ -n "$BMC_HOSTNAME_PORT" ]; then
    [ -n "$ENDPOINT" ] || ENDPOINT=$(ip -j route get "$BMC_HOSTNAME_PORT" | jq -r '.[0].prefsrc')

    read -r -s -p "Enter username and password for your BMC as 'username:password', e.g. 'root:secret':" bmc_user_pass

    bmc_mgr0=$(curl --silent --insecure --user "$bmc_user_pass" "https://$BMC_HOSTNAME_PORT/redfish/v1/Managers/" | \
               jq -r '.Members[0]."@odata.id"' | rev | cut -d '/' -f 1 | rev)

    echo "Ejecting virtual media (ignore failures)"
    curl --silent --insecure --user "$bmc_user_pass" -X POST \
        "https://$BMC_HOSTNAME_PORT/redfish/v1/Managers/$bmc_mgr0/VirtualMedia/CD/Actions/VirtualMedia.EjectMedia" \
        --header 'Content-Type: application/json' \
        --data "{}"

    echo "Inserting virtual media"
    curl --silent --insecure --user "$bmc_user_pass" -X POST \
        "https://$BMC_HOSTNAME_PORT/redfish/v1/Managers/$bmc_mgr0/VirtualMedia/CD/Actions/VirtualMedia.InsertMedia" \
        --header 'Content-Type: application/json' \
        --data "{\"Image\": \"http://$ENDPOINT/coreos-installer/bootstrap-minimal.iso\"}"

    echo "Changing boot source to Utilities"
    bmc_system0=$(curl --silent --insecure --user "$bmc_user_pass" "https://$BMC_HOSTNAME_PORT/redfish/v1/Systems/" | \
                  jq -r '.Members[0]."@odata.id"' | rev | cut -d '/' -f 1 | rev)
    curl --silent --insecure --user "$bmc_user_pass" -X PATCH \
        "https://$BMC_HOSTNAME_PORT/redfish/v1/Systems/$bmc_system0" \
        --header 'Content-Type: application/json' \
        --data '{"Boot": {"BootSourceOverrideTarget": "Utilities"}}'

    echo "Powering off server"
    curl --silent --insecure --user "$bmc_user_pass" -X POST \
        "https://$BMC_HOSTNAME_PORT/redfish/v1/Systems/$bmc_system0/Actions/ComputerSystem.Reset" \
        --header 'Content-Type: application/json' \
        --data '{"ResetType":"ForceOff"}'

    echo "Giving system time to power off"
    sleep 15

    echo "Powering on system"
    curl --silent --insecure --user "$bmc_user_pass" -X POST \
        "https://$BMC_HOSTNAME_PORT/redfish/v1/Systems/$bmc_system0/Actions/ComputerSystem.Reset" \
        --header 'Content-Type: application/json' \
        --data '{"ResetType":"On"}'

    cat << ____EOF
Server is rebooting into BIOS setup. Choose booting from virtual media, e.g. Virtual Optical Drive. Wait until
installation of Fedora CoreOS has been completed and run

   $engine stop bootstrap-httpd

to finish execution of this script.
____EOF

else
    [ -n "$ENDPOINT" ] || ENDPOINT=$(ip -j route get 1.1.1.1 | jq -r '.[0].prefsrc')

    cat << ____EOF
Point BMC of your bare-metal server to 'http://$ENDPOINT/coreos-installer/bootstrap-minimal.iso'. For example, use:

    curl -v -k -X POST https://\$BMC_HOSTNAME_PORT/redfish/v1/Managers/iDRAC.Embedded.1/VirtualMedia/CD/Actions/VirtualMedia.InsertMedia \\
        -u root \\
        -H 'Content-Type: application/json' \\
        -d '{"Image": "http://$ENDPOINT/coreos-installer/bootstrap-minimal.iso"}'

Next, reboot your server, wait until installation of Fedora CoreOS has been completed and run

   $engine stop bootstrap-httpd

to finish execution of this script."
____EOF
fi

"$engine" wait bootstrap-httpd
