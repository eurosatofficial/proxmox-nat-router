#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d)"
MOCK_BIN="$TEST_DIR/bin"

cleanup() {
  rm -rf -- "$TEST_DIR"
}
trap cleanup EXIT

mkdir -p "$MOCK_BIN"
export MOCK_LOG="$TEST_DIR/commands.log"
export MOCK_STATE="$TEST_DIR/chains"
export MOCK_SYSCTL_STATE="$TEST_DIR/ip-forward"
export NAT_ROUTER_SYSCTL_FILE="$TEST_DIR/99-proxmox-nat-router.conf"
export NAT_ROUTER_SOURCE_ONLY="yes"
export SCRIPT_UNDER_TEST="$PROJECT_DIR/nat-router.sh"

: >"$MOCK_LOG"
: >"$MOCK_STATE"
printf '0\n' >"$MOCK_SYSCTL_STATE"

cat >"$MOCK_BIN/ip" <<'EOF'
#!/usr/bin/env bash
set -u

case "$*" in
  "link show dev vmbr0" | "link show dev vmbr1")
    exit 0
    ;;
  "-4 -o addr show dev vmbr0 scope global")
    printf '2: vmbr0 inet 198.51.100.10/24 scope global vmbr0\n'
    ;;
  "-4 -o addr show dev vmbr1 scope global")
    printf '3: vmbr1 inet 10.0.0.1/24 scope global vmbr1\n'
    ;;
  *)
    printf 'Unexpected mocked ip call: %s\n' "$*" >&2
    exit 1
    ;;
esac
EOF

cat >"$MOCK_BIN/sysctl" <<'EOF'
#!/usr/bin/env bash
set -u

case "$1" in
  -n)
    cat "$MOCK_SYSCTL_STATE"
    ;;
  -q)
    value="${3#*=}"
    printf '%s\n' "$value" >"$MOCK_SYSCTL_STATE"
    ;;
  *)
    printf 'Unexpected mocked sysctl call: %s\n' "$*" >&2
    exit 1
    ;;
esac
EOF

cat >"$MOCK_BIN/iptables" <<'EOF'
#!/usr/bin/env bash
set -u

printf 'iptables %s\n' "$*" >>"$MOCK_LOG"

args=("$@")
table="filter"
operation=""
chain=""

for ((index = 0; index < ${#args[@]}; index++)); do
  case "${args[$index]}" in
    -t)
      table="${args[$((index + 1))]}"
      ;;
    -S | -N | -F | -X | -L | -C | -D | -A | -I)
      operation="${args[$index]}"
      chain="${args[$((index + 1))]:-}"
      break
      ;;
  esac
done

key="$table:$chain"

case "$operation" in
  -S)
    grep -Fxq "$key" "$MOCK_STATE"
    ;;
  -N)
    printf '%s\n' "$key" >>"$MOCK_STATE"
    ;;
  -X)
    grep -Fxv "$key" "$MOCK_STATE" >"$MOCK_STATE.tmp" || true
    mv "$MOCK_STATE.tmp" "$MOCK_STATE"
    ;;
  -L)
    printf 'Chain %s (0 references)\n' "$chain"
    printf 'num  target prot opt source destination\n'
    ;;
  -C)
    exit 1
    ;;
  -A)
    if [[ "${MOCK_FAIL_DROP:-no}" == "yes" &&
      "$chain" == "PNR_FORWARD" && "$*" == *"-j DROP"* ]]; then
      exit 42
    fi
    ;;
esac
EOF

cat >"$MOCK_BIN/iptables-save" <<'EOF'
#!/usr/bin/env bash
printf 'iptables-save %s\n' "$*" >>"$MOCK_LOG"
printf '*filter\nCOMMIT\n'
EOF

cat >"$MOCK_BIN/iptables-restore" <<'EOF'
#!/usr/bin/env bash
printf 'iptables-restore %s\n' "$*" >>"$MOCK_LOG"
EOF

cat >"$MOCK_BIN/netfilter-persistent" <<'EOF'
#!/usr/bin/env bash
printf 'netfilter-persistent %s\n' "$*" >>"$MOCK_LOG"
EOF

chmod +x "$MOCK_BIN"/*
export PATH="$MOCK_BIN:$PATH"

NAT_ROUTER_SOURCE_ONLY="no" \
  "$SCRIPT_UNDER_TEST" \
  --config "$PROJECT_DIR/example/nat-router.conf.example" check \
  >"$TEST_DIR/check-output"
grep -Fq 'Configuration is valid:' "$TEST_DIR/check-output"
grep -Fq 'Port forwards: 5' "$TEST_DIR/check-output"
grep -Fq 'CT1 tcp 2222 10.0.0.10 22' "$TEST_DIR/check-output"

run_action() {
  local action="$1"

  # Variables inside this script are intentionally expanded by the child shell.
  # shellcheck disable=SC2016
  bash -c '
    source "$SCRIPT_UNDER_TEST"
    require_root() { return 0; }
    WAN_IF="vmbr0"
    LAN_IF="vmbr1"
    LAN_NET="10.0.0.0/24"
    CT1="10.0.0.10"
    CT3="10.0.0.30"
    PORT_FORWARDS=(
      "CT1 tcp 2222 $CT1 22"
      "CT3 udp 25565 $CT3 25565"
    )
    "$1"
  ' bash "$action"
}

run_action apply_rules

grep -Fq -- '-I PREROUTING 1 -m comment --comment proxmox-nat-router -j PNR_DNAT' "$MOCK_LOG"
grep -Fq -- '-A PNR_SNAT -s 10.0.0.0/24 -o vmbr0 -j MASQUERADE' "$MOCK_LOG"
grep -Fq -- '-A PNR_FORWARD -o vmbr1 -p tcp -d 10.0.0.10 --dport 22 -m conntrack --ctstate DNAT -m comment --comment proxmox-nat-router:CT1 -j ACCEPT' "$MOCK_LOG"
grep -Fq -- '-A PNR_FORWARD -j DROP' "$MOCK_LOG"
grep -Fq -- 'netfilter-persistent save' "$MOCK_LOG"
grep -Fq -- 'net.ipv4.ip_forward=1' "$NAT_ROUTER_SYSCTL_FILE"

run_action remove_rules

if grep -Fq 'PNR_' "$MOCK_STATE"; then
  printf 'Project chains remained after remove\n' >&2
  exit 1
fi

: >"$MOCK_LOG"
export MOCK_FAIL_DROP="yes"
if run_action apply_rules; then
  printf 'Expected mocked apply failure\n' >&2
  exit 1
fi
unset MOCK_FAIL_DROP
grep -Fq -- 'iptables-restore -w 10' "$MOCK_LOG"

# shellcheck disable=SC2016
if bash -c '
  source "$SCRIPT_UNDER_TEST"
  PORT_FORWARDS=("CT1 tcp 70000 10.0.0.10 22")
  validate_port_forwards
'; then
  printf 'Expected invalid port-forward validation failure\n' >&2
  exit 1
fi

printf 'Smoke test passed\n'
