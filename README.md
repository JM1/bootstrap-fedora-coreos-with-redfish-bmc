# Bootstrap Fedora CoreOS on a bare-metal server using a Redfish BMC

This brief guide will install Fedora CoreOS on a bare-metal server, optionally using a [Redfish](
https://en.wikipedia.org/wiki/Redfish_(specification))-compatible BMC (baseboard management controller).

**NOTE:** The bootstrap process will *wipe all data* from the bare-metal server!!! ⚠️

Install `jq`, `curl` and Docker or Podman. Open [Butane](https://coreos.github.io/butane/specs/) file [config.bu](
config.bu) and customize your username and SSH public key in the `passwd.users` list. Open a shell at your local host
and enter:

```sh
sudo -s

# Define the BMC's hostname and its port (optional)
BMC_HOSTNAME_PORT="redfish-bmc.local"

# Define a hostname or ip address which your BMC can resolve and connect to (optional)
ENDPOINT=$(ip -j route get 1.1.1.1 | jq -r '.[0].prefsrc')

# Define the install destination device
INSTALL_DEVICE=/dev/sda

# Launch bootstrapping script and follow instructions on how to mount the CoreOS ISO as virtual media at your BMC
# ATTENTION: All data of your bare-metal server will be wiped, so ensure $BMC_HOSTNAME_PORT is set correctly!
./bootstrap.sh
```
