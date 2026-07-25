# Proxmox NAT Router

A focused `iptables` router for a dedicated Proxmox node with one public
bridge and one private guest bridge.

It provides:

- outbound IPv4 access through MASQUERADE
- inbound TCP and UDP port forwarding through DNAT
- hairpin NAT, so guests can use the public IP for forwarded services
- a default-deny forwarding policy
- persistent IPv4 forwarding and firewall rules
- configuration validation, status, and targeted removal commands

## Intended Topology

```text
Internet / provider gateway
            │
      physical WAN NIC
            │
    vmbr0 / public IPv4
            │
      Proxmox host
   IPv4 forwarding + NAT
            │
    vmbr1 / 10.0.0.1/24
            │
   ┌────────┼────────┐
 CT1 / VM  CT2 / VM  CT3 / VM
10.0.0.10 10.0.0.20 10.0.0.30
   gateway: 10.0.0.1
```

This project intentionally assumes:

- `vmbr0` is the only WAN bridge.
- `vmbr1` is the only private guest bridge.
- all routed guest IPv4 traffic is controlled by this script.
- the Proxmox Firewall is disabled, or its interaction has been explicitly
  tested.
- IPv6 is disabled or secured separately.

Do not use the script unchanged on a multi-LAN or SDN node.

## Requirements

Run the project as `root` on Debian/Proxmox:

```bash
apt update
apt install -y iptables iptables-persistent netfilter-persistent
```

## Installation

```bash
git clone https://github.com/eurosatofficial/proxmox-nat-router.git
cd proxmox-nat-router
cp example/nat-router.conf.example nat-router.conf
nano nat-router.conf
```

Check the configuration without changing the firewall:

```bash
./nat-router.sh check
```

Apply and save it:

```bash
./nat-router.sh apply
```

For the first application, keep the Proxmox console open. The script validates
the configuration before changing rules and automatically restores the previous
IPv4 ruleset if an application command fails, but console access is still the
safest recovery path when changing a remote firewall.

## Configuration

The script loads `nat-router.conf` from the project directory by default:

```bash
WAN_IF="vmbr0"
LAN_IF="vmbr1"
LAN_NET="10.0.0.0/24"

# Empty means: use the first global IPv4 address on WAN_IF.
WAN_IP=""

PERSIST_IP_FORWARD="yes"
XTABLES_WAIT="10"

# Keep a readable guest inventory instead of repeating bare IP addresses.
CT1="10.0.0.10" # SSH server
CT2="10.0.0.20" # Web server
CT3="10.0.0.30" # Game server

PORT_FORWARDS=(
  "CT1 tcp 2222 $CT1 22"
  "CT2 tcp 80 $CT2 80"
  "CT2 tcp 443 $CT2 443"
  "CT3 udp 25565 $CT3 25565"
)
```

Each port-forward entry has this format:

```text
<guest-label> <tcp|udp> <external-port> <destination-ip> <destination-port>
```

Guest variables such as `$CT1` keep the inventory readable, while the first
field preserves that label in validation output and as an iptables rule comment.
Use descriptive names such as `$WEB`, `$MAIL`, or `$GAME` if they provide better
oversight than numbered containers.

For compatibility, unlabeled four-field entries are still accepted. The
destination must be inside `LAN_NET`. Duplicate protocol/external-port pairs,
invalid labels, invalid addresses, and invalid ports are rejected before
firewall rules are changed.

To use a configuration stored elsewhere:

```bash
./nat-router.sh --config /etc/proxmox-nat-router.conf apply
```

## Commands

Validate the configuration:

```bash
./nat-router.sh check
```

Apply or reapply it:

```bash
./nat-router.sh apply
```

Display the active project chains:

```bash
./nat-router.sh status
```

Remove only this project's rules:

```bash
./nat-router.sh remove
```

`remove` does not flush unrelated firewall rules and intentionally leaves IPv4
forwarding enabled. If no other service needs forwarding, remove the
project-owned setting afterward:

```bash
rm /etc/sysctl.d/99-proxmox-nat-router.conf
sysctl --system
```

## What `apply` Does

1. Verifies required commands and validates the two interfaces.
2. Resolves the WAN IPv4 address used by hairpin NAT.
3. Confirms that the LAN bridge has an address inside `LAN_NET`.
4. Validates every port-forward declaration.
5. Saves the current IPv4 firewall rules for automatic error rollback.
6. Creates and rebuilds only the `PNR_*` chains.
7. Enables outbound NAT, DNAT, hairpin NAT, and stateful forwarding.
8. Adds a final drop to the dedicated forwarding chain.
9. Persists `net.ipv4.ip_forward=1` when configured.
10. Saves the resulting rules with `netfilter-persistent`.

The stable dispatcher chains keep interface-, address-, and subnet-specific
rules out of the built-in chains. Reapplying after a configuration change
therefore replaces the old project configuration rather than accumulating stale
hooks.

The first application also removes rules created by versions of this project
that used the old `MY_DNAT` and `MY_FWD` chains.

## Traffic Policy

The forwarding policy is deliberately small:

- established and related connections are accepted
- new `vmbr1` → `vmbr0` connections from `LAN_NET` are accepted
- declared DNAT connections to guest ports are accepted
- traffic inside `LAN_NET` is accepted
- all remaining forwarded IPv4 traffic is dropped

Traffic addressed to the Proxmox host itself uses the `INPUT` chain and is not
filtered by this project.

## Hairpin NAT

Guests can connect to a forwarded service through the public WAN address:

```text
guest → public WAN_IP:external-port
      → DNAT to private guest address
      → hairpin MASQUERADE for a symmetric return path
```

Hairpin NAT applies to guests entering through `LAN_IF`. Connections originating
on the Proxmox host itself do not traverse this hairpin path.

If `vmbr0` has multiple global IPv4 addresses, set `WAN_IP` explicitly instead
of relying on automatic selection.

## Proxmox Firewall

The project installs its forwarding dispatcher at the top of `FORWARD`.
Accepted or dropped traffic may therefore not reach rules managed by the
Proxmox Firewall.

For the intended dedicated-router setup, use one authoritative forwarding
policy:

- keep the Proxmox Firewall disabled and let this script own forwarding, or
- thoroughly test and document how both rule managers interact

Some Proxmox Firewall configurations also require conntrack-zone handling for
masqueraded guests. Consult the Proxmox network documentation before combining
the two systems.

## IPv6

This is an IPv4-only project. `iptables` rules do not protect IPv6 traffic.
Disable guest IPv6 or configure an independent IPv6 routing and firewall policy.

## Troubleshooting

Show complete IPv4 filter and NAT rules:

```bash
iptables -L -n -v
iptables -t nat -L -n -v
```

Check forwarding:

```bash
sysctl net.ipv4.ip_forward
```

Confirm guest configuration:

- address inside `LAN_NET`
- default gateway set to the address of `vmbr1`, normally `10.0.0.1`
- working DNS resolver

## Project Structure

```text
proxmox-nat-router/
├── README.md
├── LICENSE
├── CHANGELOG.md
├── nat-router.sh
├── example/
│   └── nat-router.conf.example
├── tests/
│   └── smoke-test.sh
└── docs/
    └── network-diagram.txt
```

Run the mocked firewall smoke test during development:

```bash
tests/smoke-test.sh
```

GitHub Actions also runs Bash syntax checks, ShellCheck, and the smoke test.

## License

MIT License
