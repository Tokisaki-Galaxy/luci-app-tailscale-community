# LuCI App for Tailscale (Community)

[![Build OpenWrt Package](https://github.com/Tokisaki-Galaxy/luci-app-tailscale-community/actions/workflows/build.yml/badge.svg)](https://github.com/Tokisaki-Galaxy/luci-app-tailscale-community/actions/workflows/build.yml)
[![License](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](https://opensource.org/licenses/Apache-2.0)
[![OpenWrt Version](https://img.shields.io/badge/OpenWrt-24.10.3-orange.svg)](https://openwrt.org/)

<p align="center">
  <a href="README.CN.md"><img src="https://img.shields.io/badge/简体中文-brightgreen.svg" alt="简体中文"></a>
  <a href="README.md"><img src="https://img.shields.io/badge/English-blue.svg" alt="English"></a>
</p>

A community-maintained LuCI application for managing Tailscale on OpenWrt. This app provides a user-friendly web interface to view Tailscale status and configure its settings directly from LuCI.

## Features

- **Status Dashboard**:
  - View the running status of the Tailscale service.
  - Display your device's Tailscale IPv4 and IPv6 addresses.
  - See your Tailnet name.
  - A detailed list of all network devices (peers), including:
    - Online/Offline status.
    - Hostname and DNS name.
    - Tailscale IPs.
    - Operating System.
    - Connection type (e.g., Direct, Relay).
    - Last seen time for offline devices.

- **Node Settings**:
  - Instantly apply settings using the `tailscale set` command without a service restart.
  - Toggle `Accept Routes`.
  - Toggle `Advertise as Exit Node`.
  - Configure `Advertise Routes`.
  - Set a specific `Exit Node` to use.
  - Toggle `Allow LAN Access` when using an exit node.
  - Enable/disable SNAT for subnet routes.
  - Enable/disable the built-in SSH server.
  - Toggle `Shields Up` mode.
  - Set a custom hostname.

- **Daemon Environment Settings**:
  - Configure environment variables for the Tailscale daemon (requires a service restart).
  - Set a custom MTU for problematic networks.
  - Enable a memory reduction mode for resource-constrained devices.

## Screenshots

*(Here you can add screenshots of the application)*

**Status Page**
![Status Page Screenshot](image/status.png)

**Settings Page**
![Settings Page Screenshot](image/setting.png)

## Installation

### Prerequisites

You must have the `tailscale` and `coreutils-base64` packages installed on your OpenWrt device.

```bash
opkg update
opkg install tailscale coreutils-base64
```

### Install the LuCI App

1. download the latest and stable `. ipk` software package from [Github Release](https://github.com/tokisaki-galaxy/Luci-app-tailscale-community/releases).
 - If you have special requirements, you can also download the latest `. ipk` software package for debugging purposes from [Github Actions Artifacts](https://github.com/actions).
2.  Transfer the `.ipk` file to your OpenWrt router (e.g., using `scp`).
3.  Install the package using `opkg`:

```bash
opkg install luci-app-tailscale-community_*.ipk
```

After installation, you should find the "Tailscale" menu under the "Services" tab in LuCI.

## Building from Source

You can also build the package yourself using the OpenWrt SDK. The build process is defined in the [`.github/workflows/build.yml`](.github/workflows/build.yml) file, which can be used as a reference.

1.  Clone the OpenWrt SDK.
2.  Clone this repository into the `package/` directory of the SDK.
3.  Run `make menuconfig` and select `luci-app-tailscale-community` under `LuCI` -> `Applications`.
4.  Run `make` to compile the package.

## License

This project is licensed under the Apache 2.0 License. See the [LICENSE](LICENSE) file for details.
