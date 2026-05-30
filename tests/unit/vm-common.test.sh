#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
VM_COMMON="$REPO_ROOT/bin/vm-common.sh"
TMP_ROOT="$(mktemp -d)"
FAILURES=0
TESTS=0

cleanup() {
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

assert_eq() {
  local expected="$1"
  local actual="$2"
  local msg="$3"
  if [[ "$expected" != "$actual" ]]; then
    echo "Assertion failed: $msg" >&2
    echo "  expected: $expected" >&2
    echo "  actual:   $actual" >&2
    return 1
  fi
}

run_test() {
  local name="$1"
  shift
  local out rc
  out="$(mktemp "$TMP_ROOT/test-output.XXXXXX")"
  TESTS=$((TESTS + 1))
  set +e
  ( set -euo pipefail; "$@" ) >"$out" 2>&1
  rc=$?
  set -e
  if [[ "$rc" -eq 0 ]]; then
    echo "ok - $name"
  else
    cat "$out" >&2
    echo "not ok - $name" >&2
    FAILURES=$((FAILURES + 1))
  fi
  rm -f "$out"
}

test_validate_instance_id_accepts_valid() {
  bash -c 'source "$1"; validate_instance_id "bot_1-a"' _ "$VM_COMMON"
}

test_validate_instance_id_rejects_invalid() {
  if bash -c 'source "$1"; validate_instance_id "bad.id"' _ "$VM_COMMON" >/dev/null 2>&1; then
    echo "Expected invalid id to fail validation" >&2
    return 1
  fi
}

test_validate_host_port_rejects_out_of_range() {
  if bash -c 'source "$1"; validate_host_port 70000' _ "$VM_COMMON" >/dev/null 2>&1; then
    echo "Expected out-of-range host port to fail validation" >&2
    return 1
  fi
}

test_next_port_finds_first_unallocated_port() {
  local state="$TMP_ROOT/state-port"
  mkdir -p "$state/.vm-a" "$state/.vm-b"
  cat > "$state/.vm-a/.env" <<'EOF'
HOST_PORT=18891
EOF
  cat > "$state/.vm-b/.env" <<'EOF'
HOST_PORT=18893
EOF

  local actual
  actual="$(STATE_ROOT="$state" BASE_PORT=18890 bash -c 'source "$1"; _host_port_in_use() { return 1; }; next_port' _ "$VM_COMMON")"
  assert_eq "18892" "$actual" "next_port should fill the first free port above BASE_PORT"
}

test_ensure_host_port_available_rejects_allocated_port() {
  local state="$TMP_ROOT/state-port-allocated"
  mkdir -p "$state/.vm-a"
  cat > "$state/.vm-a/.env" <<'EOF'
HOST_PORT=18901
EOF

  if STATE_ROOT="$state" bash -c 'source "$1"; _host_port_in_use() { return 1; }; ensure_host_port_available 18901' _ "$VM_COMMON" >/dev/null 2>&1; then
    echo "Expected allocated host port to be rejected" >&2
    return 1
  fi
}

test_ensure_host_port_available_accepts_free_port() {
  local state="$TMP_ROOT/state-port-free"
  mkdir -p "$state"

  STATE_ROOT="$state" bash -c 'source "$1"; _host_port_in_use() { return 1; }; ensure_host_port_available 18910' _ "$VM_COMMON"
}

test_ensure_host_port_available_rejects_listening_port() {
  local state="$TMP_ROOT/state-port-listening"
  mkdir -p "$state"

  if STATE_ROOT="$state" bash -c 'source "$1"; _host_port_in_use() { return 0; }; ensure_host_port_available 18910' _ "$VM_COMMON" >/dev/null 2>&1; then
    echo "Expected listening host port to be rejected" >&2
    return 1
  fi
}

test_next_port_rejects_invalid_base_port() {
  local state="$TMP_ROOT/state-port-invalid-base"
  mkdir -p "$state"

  if STATE_ROOT="$state" BASE_PORT=-1 bash -c 'source "$1"; _host_port_in_use() { return 1; }; next_port' _ "$VM_COMMON" >/dev/null 2>&1; then
    echo "Expected negative BASE_PORT to be rejected" >&2
    return 1
  fi
}

test_next_ip_uses_configured_subnet_and_fills_gap() {
  local state="$TMP_ROOT/state-ip"
  mkdir -p "$state/.vm-a" "$state/.vm-b"
  cat > "$state/.vm-a/.env" <<'EOF'
VM_IP=10.42.8.2
EOF
  cat > "$state/.vm-b/.env" <<'EOF'
VM_IP=10.42.8.4
EOF

  local actual
  actual="$(
    STATE_ROOT="$state" SUBNET_CIDR="10.42.8.0/24" BRIDGE_ADDR="10.42.8.1/24" \
      bash -c 'source "$1"; next_ip' _ "$VM_COMMON"
  )"
  assert_eq "10.42.8.3" "$actual" "next_ip should use SUBNET_CIDR and return the first available address"
}

test_next_ip_restores_nullglob() {
  local state="$TMP_ROOT/state-ip-nullglob"
  mkdir -p "$state"

  local actual
  actual="$(
    STATE_ROOT="$state" SUBNET_CIDR="10.42.8.0/24" BRIDGE_ADDR="10.42.8.1/24" \
      bash -c 'source "$1"; shopt -u nullglob; next_ip >/dev/null; if shopt -q nullglob; then echo on; else echo off; fi' _ "$VM_COMMON"
  )"
  assert_eq "off" "$actual" "next_ip should restore nullglob to its previous state"
}

test_next_ip_rejects_bridge_outside_subnet() {
  local state="$TMP_ROOT/state-ip-invalid"
  mkdir -p "$state"

  if STATE_ROOT="$state" SUBNET_CIDR="10.42.8.0/24" BRIDGE_ADDR="10.42.9.1/24" \
    bash -c 'source "$1"; next_ip' _ "$VM_COMMON" >/dev/null 2>&1; then
    echo "Expected next_ip to reject BRIDGE_ADDR outside SUBNET_CIDR" >&2
    return 1
  fi
}

test_subnet_mask_bits_rejects_non_24() {
  if SUBNET_CIDR="10.42.8.0/16" bash -c 'source "$1"; subnet_mask_bits' _ "$VM_COMMON" >/dev/null 2>&1; then
    echo "Expected subnet_mask_bits to reject non-/24 subnet" >&2
    return 1
  fi
}

test_subnet_prefix_rejects_invalid_octets() {
  if SUBNET_CIDR="999.42.8.0/24" bash -c 'source "$1"; subnet_prefix' _ "$VM_COMMON" >/dev/null 2>&1; then
    echo "Expected subnet_prefix to reject invalid IPv4 octets" >&2
    return 1
  fi
}

test_load_instance_env_treats_values_as_data() {
  local state="$TMP_ROOT/state-env-data"
  local pwned="$state/pwned"
  mkdir -p "$state/.vm-a"
  cat > "$state/.vm-a/.env" <<EOF
INSTANCE_ID=a
MODEL=\$(touch $pwned)
EOF

  STATE_ROOT="$state" bash -c 'source "$1"; load_instance_env a; [[ "$MODEL" == "\$(touch $2)" ]]' _ "$VM_COMMON" "$pwned"
  if [[ -e "$pwned" ]]; then
    echo "Expected load_instance_env to avoid executing state values" >&2
    return 1
  fi
}

run_test "validate_instance_id accepts valid IDs" test_validate_instance_id_accepts_valid
run_test "validate_instance_id rejects invalid IDs" test_validate_instance_id_rejects_invalid
run_test "validate_host_port rejects out-of-range values" test_validate_host_port_rejects_out_of_range
run_test "next_port fills first unallocated port" test_next_port_finds_first_unallocated_port
run_test "ensure_host_port_available rejects allocated port" test_ensure_host_port_available_rejects_allocated_port
run_test "ensure_host_port_available accepts free port" test_ensure_host_port_available_accepts_free_port
run_test "ensure_host_port_available rejects listening port" test_ensure_host_port_available_rejects_listening_port
run_test "next_port rejects invalid BASE_PORT" test_next_port_rejects_invalid_base_port
run_test "next_ip uses configured subnet and fills gaps" test_next_ip_uses_configured_subnet_and_fills_gap
run_test "next_ip restores nullglob" test_next_ip_restores_nullglob
run_test "next_ip rejects bridge outside subnet" test_next_ip_rejects_bridge_outside_subnet
run_test "subnet_mask_bits rejects non-/24 values" test_subnet_mask_bits_rejects_non_24
run_test "subnet_prefix rejects invalid octets" test_subnet_prefix_rejects_invalid_octets
run_test "load_instance_env treats values as data" test_load_instance_env_treats_values_as_data

if (( FAILURES > 0 )); then
  echo
  echo "$FAILURES of $TESTS tests failed" >&2
  exit 1
fi

echo
echo "All $TESTS tests passed"
