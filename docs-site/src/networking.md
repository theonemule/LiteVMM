---
layout: layout.njk
title: Networking
---
# Networks

The **Networks** menu is a single inventory for physical host adapters, Linux bridges, Docker networks, and GOST TAP overlays. They are different tools, even though all appear in the same table.

| Type | What it is | Typical use |
| --- | --- | --- |
| **Interface** | A physical or host network adapter detected by Linux. | A component used to build a bridge; it is managed by the operating system. |
| **Linux bridge** | A host Layer-2 software switch. | Put VM NICs and a physical adapter on the same LAN segment. |
| **Docker network** | A Docker-managed network namespace and IPAM network. | Let containers communicate by name on an isolated application network. |
| **GOST TAP overlay** | A Layer-2 Ethernet tunnel between paired LiteVMM hosts, carried over authenticated WebSockets. | Extend a VM network between hosts you control. |

## Create a Linux bridge

Select **Create network**, choose **Linux bridge**, then continue. Give it a bridge name and configure its address mode, address, gateway, member interfaces, and persistence. Select a physical adapter only when you understand the host's current network path.

A bridge behaves like a switch. A VM using bridge mode becomes a Layer-2 peer of the bridge. Moving the host's management adapter into a bridge can cut off your current web session, so make this change only with console access and a rollback plan. **Edit** changes bridge configuration. **Delete** removes the bridge and detaches its ports.

Physical **Interface** rows cannot be configured directly here. Their **Edit** action starts the bridge-creation flow so the adapter can be used as a bridge member.

## Create a Docker network

Select **Create network**, choose **Docker network**, then set:

| Setting | Meaning |
| --- | --- |
| **Name** | The network name containers use. |
| **Driver** | Usually `bridge`, Docker's local virtual network driver. |
| **Subnet** | The container network CIDR, such as `172.30.0.0/24`. Do not overlap an existing LAN, VPN, or Docker network. |
| **Gateway** | The gateway address within that subnet, such as `172.30.0.1`. |
| **Internal-only** | Prevents external connectivity through this Docker network; use it for back-end-only services. |

**Edit** displays the existing Docker settings. Docker addressing is immutable, so saving an edit removes and recreates an unused network. Disconnect containers first. **Delete** removes the Docker network and requires no attached endpoints.

## Create a GOST TAP overlay

An overlay is not Docker Swarm overlay networking. In LiteVMM it is a Layer-2 TAP tunnel over the paired hosts' existing HTTP(S)/WebSocket route. It allows attached VM interfaces to behave as though they are on the same Ethernet segment across hosts, including ARP and DHCP broadcasts.

Before creating one, pair the hosts in **Cluster**, set each peer endpoint, and make sure the peers show a usable relay configuration. Then select **Create network** → **GOST TAP overlay** and set:

| Setting | Meaning |
| --- | --- |
| **Network name** | A short overlay identity. It cannot be changed during edit. |
| **Linux bridge** | The local bridge that carries the overlay's Ethernet frames. Create or plan this bridge first. |
| **Topology role** | **Hub** can accept multiple paired peers. **Spoke** connects to exactly one hub. |
| **MTU** | The maximum frame size for the tunneled path. The default 1400 leaves room for tunnel overhead; use a value that matches the complete path. |
| **Paired hosts** | The trusted peers at the other end. A spoke must select one; a hub may select several. |

Editing an overlay recreates its transport. Disconnect attached workloads first. Deleting it also requires attached workloads to be disconnected. Use **Validate** in the Networks table to confirm that GOST is alive, the local device is a TAP device, its link is up, and it is attached to the selected bridge. An **Incomplete overlay** row means a previous operation stopped mid-way; its **Delete** button removes the leftover overlay network and bridge together after confirmation.

LiteVMM does not automatically attach a Docker bridge network to a TAP overlay. Docker bridge IPAM is host-local; putting the same Docker gateway/subnet on every host would conflict within the shared Ethernet segment. Use the overlay for VM NICs, or use a distributed Docker network driver for multi-host containers.

## Choose the right one

Use a **Linux bridge** when a VM must join a local physical/LAN segment. Use a **Docker network** for container-to-container application connectivity on one Docker host. Use an **overlay** only when you need Layer-2 connectivity between paired LiteVMM hosts; it depends on the bridge underneath it and has more failure modes than a local network. Use **NAT** on a VM when it only needs ordinary outbound access and does not need to be a direct LAN peer.

## VM access VLANs

For a bridged VM NIC, an optional VLAN ID from 1 through 4094 creates a managed TAP access port. Traffic is untagged at the guest-facing TAP and associated with the selected 802.1Q VLAN on the Linux bridge. LiteVMM enables bridge VLAN filtering and permits that VLAN on the bridge uplink ports; the upstream switch or nested virtualization network still has to carry the VLAN. Leave VLAN blank when the guest should use the bridge without access-VLAN filtering.
