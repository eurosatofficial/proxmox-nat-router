# Changelog

## 1.1.0 - 2026-07-25

- Added `apply`, `check`, `status`, and targeted `remove` commands
- Added preflight validation for interfaces, addresses, subnet, and forwards
- Added automatic restoration of the previous IPv4 ruleset on command failure
- Added stable project-owned `PNR_*` dispatcher chains
- Added cleanup and migration of the original `MY_*` chains
- Restricted forwarded-port acceptance to connections that were DNATed
- Added xtables lock waiting
- Added persistent IPv4 forwarding through `sysctl.d`
- Moved local settings and port forwards into `nat-router.conf`
- Preserved named guest variables and labels in port-forward rules
- Expanded the dedicated two-bridge diagram and safety documentation

## 1.0.1 - 2026-07-12

- Added hairpin DNAT and SNAT

## 1.0.0

- Initial release
- NAT/MASQUERADE for the Proxmox LAN network
- DNAT port-forward helper
- Dedicated iptables chains
- Example configuration
