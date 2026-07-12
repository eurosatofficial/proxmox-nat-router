# Proxmox NAT Router

A simple `iptables` script that turns a Proxmox host into a NAT router for an internal VM/LXC network.

The script is intentionally lightweight and works well for setups with:

- a public WAN interface, e.g. `vmbr0`
- an internal LAN interface, e.g. `vmbr1`
- a private VM/LXC network, e.g. `10.0.0.0/24`
- outbound internet access via MASQUERADE
- inbound port forwarding via DNAT

## Network Layout

```text
Internet
   │
   │ Public IP
   │
vmbr0 / WAN
   │
Proxmox Host
   │
vmbr1 / LAN
   │
10.0.0.0/24
   │
   ├── VM / CT 10.0.0.10
   ├── VM / CT 10.0.0.20
   └── VM / CT 10.0.0.30
```

## Requirements

On Debian/Proxmox:

```bash
apt update && apt install -y iptables netfilter-persistent iptables-persistent
```

## Installation

Clone the repository:

```bash
git clone https://github.com/USERNAME/proxmox-nat-router.git
```

Change into the project directory:

```bash
cd proxmox-nat-router
```

Make the script executable:

```bash
chmod +x nat-router.sh
```

Edit the script:

```bash
nano nat-router.sh
```

Then run it:

```bash
./nat-router.sh
```

## Configuration

At the top of the script, configure your interfaces and LAN subnet:

```bash
WAN_IF="vmbr0"
LAN_IF="vmbr1"
LAN_NET="10.0.0.0/24"
```

Adjust these values to match your Proxmox network configuration.

## Adding Port Forwarding Rules

Port forwarding is configured using the `fwd` function:

```bash
fwd <tcp|udp> <external_port> <destination_ip> <destination_port>
```

Example for forwarding SSH to an internal VM:

```bash
SERVER="10.0.0.10"
fwd tcp 2222 $SERVER 22
```

This forwards external port `2222/tcp` to `10.0.0.10:22`.

Example for HTTP/HTTPS:

```bash
WEBSERVER="10.0.0.20"
fwd tcp 80 $WEBSERVER 80
fwd tcp 443 $WEBSERVER 443
```

Example for a game server:

```bash
GAMESERVER="10.0.0.30"
fwd tcp 25565 $GAMESERVER 25565
fwd udp 25565 $GAMESERVER 25565
```

**Important:** Port forwarding rules must be placed before the final DROP rule in the script.

## What the Script Does

The script:

1. Enables IPv4 forwarding.
2. Creates the custom chains `MY_DNAT` and `MY_FWD`.
3. Hooks `MY_DNAT` into the `PREROUTING` chain.
4. Inserts `MY_FWD` at the top of the `FORWARD` chain.
5. Configures MASQUERADE for outbound LAN traffic.
6. Allows established and related return traffic.
7. Allows LAN → WAN traffic.
8. Allows LAN ↔ LAN traffic.
9. Applies a final DROP rule.
10. Saves all rules using `netfilter-persistent save`.

## Safe to Run Multiple Times

The script can be executed repeatedly. Its custom chains are flushed and recreated each time, making it safe to reapply changes.

## Viewing the Rules

Display NAT rules:

```bash
iptables -t nat -L -n -v
```

Display forwarding rules:

```bash
iptables -L -n -v
```

## Removing the Rules

Flush all persistent rules:

```bash
iptables -F && iptables -t nat -F && netfilter-persistent save
```

Remove the custom chains if they are no longer needed:

```bash
iptables -D FORWARD -j MY_FWD 2>/dev/null || true; iptables -F MY_FWD 2>/dev/null || true; iptables -X MY_FWD 2>/dev/null || true; iptables -t nat -D PREROUTING -i vmbr0 -j MY_DNAT 2>/dev/null || true; iptables -t nat -F MY_DNAT 2>/dev/null || true; iptables -t nat -X MY_DNAT 2>/dev/null || true; netfilter-persistent save
```

## Notes About the Proxmox Firewall

The script inserts its custom forwarding chain at the very top of the `FORWARD` chain. This ensures that matching NAT/DNAT rules are processed before other forwarding rules can unintentionally block them.

If you also use the Proxmox Firewall, thoroughly test your setup and clearly document which layer is responsible for which functionality.

## Project Structure

```text
proxmox-nat-router/
├── README.md
├── LICENSE
├── nat-router.sh
├── example/
│   └── nat-router.example.sh
└── docs/
    └── network-diagram.txt
```

## License

MIT License