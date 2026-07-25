#!/usr/bin/env bash
set -Eeuo pipefail

PROGRAM_NAME="${0##*/}"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

readonly PROGRAM_NAME SCRIPT_DIR
readonly CHAIN_DNAT="PNR_DNAT"
readonly CHAIN_PORTS="PNR_PORTS"
readonly CHAIN_SNAT="PNR_SNAT"
readonly CHAIN_FORWARD="PNR_FORWARD"
readonly RULE_COMMENT="proxmox-nat-router"
SYSCTL_FILE="${NAT_ROUTER_SYSCTL_FILE:-/etc/sysctl.d/99-proxmox-nat-router.conf}"
readonly SYSCTL_FILE
readonly LEGACY_DNAT_CHAIN="MY_DNAT"
readonly LEGACY_FORWARD_CHAIN="MY_FWD"

# Defaults. Override them in nat-router.conf or with --config FILE.
WAN_IF="vmbr0"
LAN_IF="vmbr1"
LAN_NET="10.0.0.0/24"
WAN_IP=""
PERSIST_IP_FORWARD="yes"
XTABLES_WAIT="10"
PORT_FORWARDS=()

ACTION="apply"
ACTION_SET="no"
CONFIG_FILE="${NAT_ROUTER_CONFIG:-}"
ROLLBACK_FILE=""
PREVIOUS_IP_FORWARD=""
APPLY_COMMITTED="no"
LAN_ROUTER_IP=""
FWD_LABEL=""
FWD_PROTOCOL=""
FWD_EXTERNAL_PORT=""
FWD_DESTINATION_IP=""
FWD_DESTINATION_PORT=""

log() {
  printf '%s\n' "$*"
}

warn() {
  printf 'Warning: %s\n' "$*" >&2
}

die() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<EOF
Usage: $PROGRAM_NAME [--config FILE] [apply|check|status|remove]

Commands:
  apply    Validate, apply, and persist the NAT rules (default)
  check    Validate the configuration without changing the system
  status   Display this project's active rules
  remove   Remove only this project's firewall rules

Configuration defaults to ./nat-router.conf when that file exists.
EOF
}

parse_args() {
  while (($# > 0)); do
    case "$1" in
      --config)
        (($# >= 2)) || die "--config requires a file path"
        CONFIG_FILE="$2"
        shift 2
        ;;
      apply | check | status | remove)
        [[ "$ACTION_SET" == "no" ]] || die "only one command may be specified"
        ACTION="$1"
        ACTION_SET="yes"
        shift
        ;;
      -h | --help)
        usage
        exit 0
        ;;
      *)
        die "unknown argument: $1"
        ;;
    esac
  done
}

load_config() {
  if [[ -z "$CONFIG_FILE" && -f "$SCRIPT_DIR/nat-router.conf" ]]; then
    CONFIG_FILE="$SCRIPT_DIR/nat-router.conf"
  fi

  if [[ -n "$CONFIG_FILE" ]]; then
    [[ -r "$CONFIG_FILE" ]] || die "configuration is not readable: $CONFIG_FILE"
    # The configuration is a trusted, root-owned shell fragment.
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"
  fi
}

require_root() {
  ((EUID == 0)) || die "this command must be run as root"
}

require_commands() {
  local command_name
  local -a commands=(
    awk
    ip
    iptables
    iptables-restore
    iptables-save
    netfilter-persistent
    sysctl
  )

  if [[ "$PERSIST_IP_FORWARD" == "yes" ]]; then
    commands+=(install mktemp)
  fi

  for command_name in "${commands[@]}"; do
    command -v "$command_name" >/dev/null 2>&1 ||
      die "required command not found: $command_name"
  done
}

is_ipv4() {
  local address="$1"
  local octet
  local -a octets

  IFS='.' read -r -a octets <<<"$address"
  ((${#octets[@]} == 4)) || return 1

  for octet in "${octets[@]}"; do
    [[ "$octet" =~ ^[0-9]{1,3}$ ]] || return 1
    ((10#$octet <= 255)) || return 1
  done
}

is_ipv4_cidr() {
  local cidr="$1"
  local address prefix

  [[ "$cidr" == */* ]] || return 1
  address="${cidr%/*}"
  prefix="${cidr##*/}"

  is_ipv4 "$address" || return 1
  [[ "$prefix" =~ ^[0-9]{1,2}$ ]] || return 1
  ((10#$prefix <= 32))
}

ipv4_to_integer() {
  local address="$1"
  local a b c d

  IFS='.' read -r a b c d <<<"$address"
  printf '%u\n' "$(((10#$a << 24) | (10#$b << 16) | (10#$c << 8) | 10#$d))"
}

cidr_contains() {
  local address="$1"
  local cidr="$2"
  local network prefix address_integer network_integer mask

  network="${cidr%/*}"
  prefix="${cidr##*/}"
  address_integer="$(ipv4_to_integer "$address")"
  network_integer="$(ipv4_to_integer "$network")"

  if ((10#$prefix == 0)); then
    mask=0
  else
    mask=$(((0xFFFFFFFF << (32 - 10#$prefix)) & 0xFFFFFFFF))
  fi

  (( (address_integer & mask) == (network_integer & mask) ))
}

is_port() {
  local port="$1"

  [[ "$port" =~ ^[0-9]{1,5}$ ]] || return 1
  ((10#$port >= 1 && 10#$port <= 65535))
}

resolve_addresses() {
  local address cidr
  local -a wan_addresses=()
  local -a lan_addresses=()

  while IFS= read -r address; do
    wan_addresses+=("$address")
  done < <(
    ip -4 -o addr show dev "$WAN_IF" scope global |
      awk '{split($4, address, "/"); print address[1]}'
  )
  ((${#wan_addresses[@]} > 0)) ||
    die "$WAN_IF has no global IPv4 address"

  if [[ -n "$WAN_IP" ]]; then
    is_ipv4 "$WAN_IP" || die "invalid WAN_IP: $WAN_IP"
    local assigned="no"
    for address in "${wan_addresses[@]}"; do
      if [[ "$address" == "$WAN_IP" ]]; then
        assigned="yes"
        break
      fi
    done
    [[ "$assigned" == "yes" ]] ||
      die "WAN_IP $WAN_IP is not assigned to $WAN_IF"
  else
    WAN_IP="${wan_addresses[0]}"
    if ((${#wan_addresses[@]} > 1)); then
      warn "$WAN_IF has multiple IPv4 addresses; using $WAN_IP for hairpin NAT"
      warn "set WAN_IP explicitly in nat-router.conf to select another address"
    fi
  fi

  while IFS= read -r cidr; do
    lan_addresses+=("$cidr")
  done < <(
    ip -4 -o addr show dev "$LAN_IF" scope global | awk '{print $4}'
  )

  for cidr in "${lan_addresses[@]}"; do
    address="${cidr%/*}"
    if is_ipv4 "$address" && cidr_contains "$address" "$LAN_NET"; then
      LAN_ROUTER_IP="$address"
      break
    fi
  done

  [[ -n "$LAN_ROUTER_IP" ]] ||
    die "$LAN_IF has no IPv4 address inside $LAN_NET"
}

validate_port_forwards() {
  local specification
  local key seen=" "

  for specification in "${PORT_FORWARDS[@]}"; do
    parse_port_forward "$specification" ||
      die "invalid port forward: '$specification'"
    [[ "$FWD_LABEL" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]{0,31}$ ]] ||
      die "invalid guest label in: '$specification'"
    [[ "$FWD_PROTOCOL" == "tcp" || "$FWD_PROTOCOL" == "udp" ]] ||
      die "port-forward protocol must be tcp or udp: '$specification'"
    is_port "$FWD_EXTERNAL_PORT" ||
      die "invalid external port in: '$specification'"
    is_ipv4 "$FWD_DESTINATION_IP" ||
      die "invalid destination IPv4 address in: '$specification'"
    cidr_contains "$FWD_DESTINATION_IP" "$LAN_NET" ||
      die "port-forward destination is outside $LAN_NET: '$specification'"
    is_port "$FWD_DESTINATION_PORT" ||
      die "invalid destination port in: '$specification'"

    key="$FWD_PROTOCOL/$FWD_EXTERNAL_PORT"
    [[ "$seen" != *" $key "* ]] ||
      die "duplicate external port forward: $key"
    seen+="$key "
  done
}

parse_port_forward() {
  local specification="$1"
  local first second third fourth fifth extra

  first=""
  second=""
  third=""
  fourth=""
  fifth=""
  extra=""
  read -r first second third fourth fifth extra <<<"$specification"

  if [[ "$first" == "tcp" || "$first" == "udp" ]]; then
    [[ -n "$fourth" && -z "$fifth" && -z "$extra" ]] || return 1
    FWD_LABEL="$third"
    FWD_PROTOCOL="$first"
    FWD_EXTERNAL_PORT="$second"
    FWD_DESTINATION_IP="$third"
    FWD_DESTINATION_PORT="$fourth"
  else
    [[ -n "$fifth" && -z "$extra" ]] || return 1
    FWD_LABEL="$first"
    FWD_PROTOCOL="$second"
    FWD_EXTERNAL_PORT="$third"
    FWD_DESTINATION_IP="$fourth"
    FWD_DESTINATION_PORT="$fifth"
  fi
}

validate_config() {
  [[ -n "$WAN_IF" ]] || die "WAN_IF must not be empty"
  [[ -n "$LAN_IF" ]] || die "LAN_IF must not be empty"
  [[ "$WAN_IF" != "$LAN_IF" ]] || die "WAN_IF and LAN_IF must be different"
  is_ipv4_cidr "$LAN_NET" || die "invalid LAN_NET: $LAN_NET"
  [[ "$PERSIST_IP_FORWARD" == "yes" || "$PERSIST_IP_FORWARD" == "no" ]] ||
    die "PERSIST_IP_FORWARD must be yes or no"
  [[ "$XTABLES_WAIT" =~ ^[0-9]+$ ]] ||
    die "XTABLES_WAIT must be a non-negative integer"

  ip link show dev "$WAN_IF" >/dev/null 2>&1 ||
    die "WAN interface does not exist: $WAN_IF"
  ip link show dev "$LAN_IF" >/dev/null 2>&1 ||
    die "LAN interface does not exist: $LAN_IF"

  resolve_addresses
  validate_port_forwards
}

ipt() {
  iptables --wait "$XTABLES_WAIT" "$@"
}

chain_exists() {
  local table="$1"
  local chain="$2"

  ipt -t "$table" -S "$chain" >/dev/null 2>&1
}

ensure_empty_chain() {
  local table="$1"
  local chain="$2"

  if ! chain_exists "$table" "$chain"; then
    ipt -t "$table" -N "$chain"
  fi
  ipt -t "$table" -F "$chain"
}

delete_chain_if_present() {
  local table="$1"
  local chain="$2"

  if chain_exists "$table" "$chain"; then
    ipt -t "$table" -F "$chain"
    ipt -t "$table" -X "$chain"
  fi
}

delete_references() {
  local table="$1"
  local parent_chain="$2"
  local target_chain="$3"
  local line_number

  while true; do
    line_number="$(
      LC_ALL=C ipt -t "$table" -L "$parent_chain" --line-numbers -n |
        awk -v target="$target_chain" '$2 == target {print $1; exit}'
    )"
    [[ -n "$line_number" ]] || break
    ipt -t "$table" -D "$parent_chain" "$line_number"
  done
}

delete_exact_rule() {
  local table="$1"
  shift

  while ipt -t "$table" -C "$@" >/dev/null 2>&1; do
    ipt -t "$table" -D "$@"
  done
}

remove_legacy_rules() {
  delete_references nat PREROUTING "$LEGACY_DNAT_CHAIN"
  delete_references filter FORWARD "$LEGACY_FORWARD_CHAIN"

  delete_exact_rule nat POSTROUTING \
    -s "$LAN_NET" -o "$WAN_IF" -j MASQUERADE
  delete_exact_rule nat POSTROUTING \
    -s "$LAN_NET" -d "$LAN_NET" -m conntrack --ctstate DNAT -j MASQUERADE

  delete_chain_if_present nat "$LEGACY_DNAT_CHAIN"
  delete_chain_if_present filter "$LEGACY_FORWARD_CHAIN"
}

start_rollback_guard() {
  APPLY_COMMITTED="no"
  umask 077
  ROLLBACK_FILE="$(mktemp /tmp/proxmox-nat-router.XXXXXX)"
  PREVIOUS_IP_FORWARD="$(sysctl -n net.ipv4.ip_forward)"
  trap 'finish_or_rollback "$?"' EXIT
  iptables-save -w "$XTABLES_WAIT" >"$ROLLBACK_FILE"
}

finish_or_rollback() {
  local result="$1"
  trap - EXIT

  if ((result != 0)) && [[ "$APPLY_COMMITTED" != "yes" && -s "$ROLLBACK_FILE" ]]; then
    warn "operation failed; restoring the previous IPv4 firewall rules"
    iptables-restore -w "$XTABLES_WAIT" "$ROLLBACK_FILE" || true
    if [[ -n "$PREVIOUS_IP_FORWARD" ]]; then
      sysctl -q -w "net.ipv4.ip_forward=$PREVIOUS_IP_FORWARD" || true
    fi
  fi

  if [[ -n "$ROLLBACK_FILE" ]]; then
    rm -f -- "$ROLLBACK_FILE"
  fi

  exit "$result"
}

add_port_forward() {
  local label="$1"
  local proto="$2"
  local external_port="$3"
  local destination_ip="$4"
  local destination_port="$5"

  ipt -t nat -A "$CHAIN_PORTS" \
    -p "$proto" --dport "$external_port" \
    -m comment --comment "$RULE_COMMENT:$label" \
    -j DNAT --to-destination "${destination_ip}:${destination_port}"

  ipt -A "$CHAIN_FORWARD" \
    -o "$LAN_IF" -p "$proto" -d "$destination_ip" --dport "$destination_port" \
    -m conntrack --ctstate DNAT \
    -m comment --comment "$RULE_COMMENT:$label" -j ACCEPT
}

configure_port_forwards() {
  local specification

  for specification in "${PORT_FORWARDS[@]}"; do
    parse_port_forward "$specification"
    add_port_forward \
      "$FWD_LABEL" \
      "$FWD_PROTOCOL" \
      "$FWD_EXTERNAL_PORT" \
      "$FWD_DESTINATION_IP" \
      "$FWD_DESTINATION_PORT"
  done
}

persist_ip_forwarding() {
  local temporary_file

  [[ "$PERSIST_IP_FORWARD" == "yes" ]] || return 0

  temporary_file="$(mktemp /tmp/proxmox-nat-router-sysctl.XXXXXX)"
  {
    printf '# Managed by proxmox-nat-router\n'
    printf 'net.ipv4.ip_forward=1\n'
  } >"$temporary_file"
  install -m 0644 "$temporary_file" "$SYSCTL_FILE"
  rm -f -- "$temporary_file"
}

apply_rules() {
  require_root
  require_commands
  validate_config

  log "Configuration valid:"
  log "  WAN: $WAN_IF ($WAN_IP)"
  log "  LAN: $LAN_IF ($LAN_NET, router $LAN_ROUTER_IP)"
  log "  Port forwards: ${#PORT_FORWARDS[@]}"

  start_rollback_guard
  sysctl -q -w net.ipv4.ip_forward=1

  # Detach existing project hooks before rebuilding the owned chains.
  delete_references nat PREROUTING "$CHAIN_DNAT"
  delete_references nat POSTROUTING "$CHAIN_SNAT"
  delete_references filter FORWARD "$CHAIN_FORWARD"
  remove_legacy_rules

  ensure_empty_chain nat "$CHAIN_DNAT"
  ensure_empty_chain nat "$CHAIN_PORTS"
  ensure_empty_chain nat "$CHAIN_SNAT"
  ensure_empty_chain filter "$CHAIN_FORWARD"

  # Incoming and hairpin traffic share one validated port-forward list.
  ipt -t nat -A "$CHAIN_DNAT" -i "$WAN_IF" -j "$CHAIN_PORTS"
  ipt -t nat -A "$CHAIN_DNAT" \
    -i "$LAN_IF" -d "$WAN_IP" -j "$CHAIN_PORTS"

  # Outbound and hairpin source NAT.
  ipt -t nat -A "$CHAIN_SNAT" \
    -s "$LAN_NET" -o "$WAN_IF" -j MASQUERADE
  ipt -t nat -A "$CHAIN_SNAT" \
    -s "$LAN_NET" -d "$LAN_NET" \
    -m conntrack --ctstate DNAT -j MASQUERADE

  # Dedicated two-zone forwarding policy.
  ipt -A "$CHAIN_FORWARD" \
    -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
  ipt -A "$CHAIN_FORWARD" \
    -i "$LAN_IF" -o "$WAN_IF" -s "$LAN_NET" \
    -m conntrack --ctstate NEW -j ACCEPT

  configure_port_forwards

  # Same-bridge traffic is normally switched, but this also covers hairpin flows
  # and hosts where bridged IPv4 traffic is passed through iptables.
  ipt -A "$CHAIN_FORWARD" -s "$LAN_NET" -d "$LAN_NET" -j ACCEPT
  ipt -A "$CHAIN_FORWARD" -j DROP

  # Attach only fully built chains to the live packet path.
  ipt -t nat -I PREROUTING 1 \
    -m comment --comment "$RULE_COMMENT" -j "$CHAIN_DNAT"
  ipt -t nat -I POSTROUTING 1 \
    -m comment --comment "$RULE_COMMENT" -j "$CHAIN_SNAT"
  ipt -I FORWARD 1 \
    -m comment --comment "$RULE_COMMENT" -j "$CHAIN_FORWARD"

  persist_ip_forwarding
  netfilter-persistent save

  APPLY_COMMITTED="yes"
  log "NAT router rules applied and saved."
}

check_config() {
  local specification

  require_commands
  validate_config

  log "Configuration is valid:"
  log "  WAN: $WAN_IF ($WAN_IP)"
  log "  LAN: $LAN_IF ($LAN_NET, router $LAN_ROUTER_IP)"
  log "  Port forwards: ${#PORT_FORWARDS[@]}"
  for specification in "${PORT_FORWARDS[@]}"; do
    log "    $specification"
  done
}

show_status() {
  local found="no"
  local table chain table_and_chain

  require_root
  require_commands

  log "IPv4 forwarding: $(sysctl -n net.ipv4.ip_forward)"
  if [[ -f "$SYSCTL_FILE" ]]; then
    log "Persistent forwarding: managed by $SYSCTL_FILE"
  else
    warn "persistent forwarding file is not installed"
  fi

  for table_and_chain in \
    "nat:$CHAIN_DNAT" \
    "nat:$CHAIN_PORTS" \
    "nat:$CHAIN_SNAT" \
    "filter:$CHAIN_FORWARD"; do
    table="${table_and_chain%%:*}"
    chain="${table_and_chain##*:}"
    if chain_exists "$table" "$chain"; then
      found="yes"
      log ""
      ipt -t "$table" -S "$chain"
    fi
  done

  [[ "$found" == "yes" ]] || log "No proxmox-nat-router rules are active."
}

remove_rules() {
  require_root
  require_commands
  is_ipv4_cidr "$LAN_NET" || die "invalid LAN_NET: $LAN_NET"
  [[ -n "$WAN_IF" ]] || die "WAN_IF must not be empty"

  start_rollback_guard

  delete_references nat PREROUTING "$CHAIN_DNAT"
  delete_references nat POSTROUTING "$CHAIN_SNAT"
  delete_references filter FORWARD "$CHAIN_FORWARD"
  remove_legacy_rules

  # Flush dispatchers first so their child chains are no longer referenced.
  delete_chain_if_present nat "$CHAIN_DNAT"
  delete_chain_if_present filter "$CHAIN_FORWARD"
  delete_chain_if_present nat "$CHAIN_SNAT"
  delete_chain_if_present nat "$CHAIN_PORTS"

  netfilter-persistent save
  APPLY_COMMITTED="yes"

  log "proxmox-nat-router firewall rules removed and saved."
  if [[ -f "$SYSCTL_FILE" ]]; then
    log "Persistent IPv4 forwarding remains enabled in $SYSCTL_FILE."
  fi
}

main() {
  parse_args "$@"
  load_config

  case "$ACTION" in
    apply)
      apply_rules
      ;;
    check)
      check_config
      ;;
    status)
      show_status
      ;;
    remove)
      remove_rules
      ;;
  esac
}

if [[ "${NAT_ROUTER_SOURCE_ONLY:-no}" != "yes" ]]; then
  main "$@"
fi
