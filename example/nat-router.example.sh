#!/bin/bash
set -e

WAN_IF="vmbr0"
LAN_IF="vmbr1"
LAN_NET="10.0.0.0/24"
WAN_IP="$(ip -4 -o addr show dev "$WAN_IF" scope global | awk '{split($4,a,"/"); print a[1]; exit}')"

sysctl -w net.ipv4.ip_forward=1 >/dev/null

# Chains
iptables -t nat -N MY_DNAT 2>/dev/null || true
iptables -t nat -F MY_DNAT

iptables -N MY_FWD 2>/dev/null || true
iptables -F MY_FWD

# Hooks (ganz nach oben)
iptables -t nat -C PREROUTING -i "$WAN_IF" -j MY_DNAT 2>/dev/null || \
iptables -t nat -I PREROUTING 1 -i "$WAN_IF" -j MY_DNAT

# Hairpin-DNAT: öffentliche IP auch aus dem internen Netz weiterleiten
iptables -t nat -C PREROUTING -i "$LAN_IF" -d "$WAN_IP" -j MY_DNAT 2>/dev/null || iptables -t nat -I PREROUTING 1 -i "$LAN_IF" -d "$WAN_IP" -j MY_DNAT

# Jump in FORWARD sicher an Position 1
iptables -D FORWARD -j MY_FWD 2>/dev/null || true
iptables -I FORWARD 1 -j MY_FWD

# SNAT
iptables -t nat -C POSTROUTING -s "$LAN_NET" -o "$WAN_IF" -j MASQUERADE 2>/dev/null || \
iptables -t nat -A POSTROUTING -s "$LAN_NET" -o "$WAN_IF" -j MASQUERADE

# Hairpin-SNAT: Rückverkehr interner DNAT-Verbindungen über den Router führen
iptables -t nat -C POSTROUTING -s "$LAN_NET" -d "$LAN_NET" -m conntrack --ctstate DNAT -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -s "$LAN_NET" -d "$LAN_NET" -m conntrack --ctstate DNAT -j MASQUERADE

# Return traffic
iptables -A MY_FWD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

# LAN -> WAN Outgoing erlauben
iptables -A MY_FWD -i "$LAN_IF" -o "$WAN_IF" -s "$LAN_NET" \
  -m conntrack --ctstate NEW,ESTABLISHED,RELATED -j ACCEPT

# Portforward Helper
fwd() {
  local proto="$1" extport="$2" dstip="$3" dstport="$4"
  iptables -t nat -A MY_DNAT -p "$proto" --dport "$extport" -j DNAT --to-destination "${dstip}:${dstport}"
  iptables -A MY_FWD -p "$proto" -d "$dstip" --dport "$dstport" -m conntrack --ctstate NEW -j ACCEPT
}

# --------------------------------------------------------------------
# Portforwards
# Format: fwd <tcp|udp> <externer_port> <ziel_ip> <ziel_port>
# --------------------------------------------------------------------

# SSH auf interne VM
SERVER="10.0.0.10"
fwd tcp 2222 $SERVER 22

# Webserver
WEBSERVER="10.0.0.20"
fwd tcp 80 $WEBSERVER 80
fwd tcp 443 $WEBSERVER 443

# Game-Server
GAMESERVER="10.0.0.30"
fwd tcp 25565 $GAMESERVER 25565
fwd udp 25565 $GAMESERVER 25565

# LAN <-> LAN erlauben (interne Kommunikation)
iptables -A MY_FWD -s "$LAN_NET" -d "$LAN_NET" -j ACCEPT

# Final Drop
iptables -A MY_FWD -j DROP

netfilter-persistent save
echo "✅ NAT + Outgoing + DNAT aktiv"
