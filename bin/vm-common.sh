#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)}"
FC_ROOT="${FC_ROOT:-/srv/firecracker/vm-demo}"
STATE_ROOT="${STATE_ROOT:-/var/lib/fireclaw}"
BASE_PORT="${BASE_PORT:-18890}"

BRIDGE_NAME="${BRIDGE_NAME:-fc-br0}"
BRIDGE_ADDR="${BRIDGE_ADDR:-172.16.0.1/24}"
SUBNET_CIDR="${SUBNET_CIDR:-172.16.0.0/24}"

OPENCLAW_IMAGE_DEFAULT="${OPENCLAW_IMAGE_DEFAULT:-ghcr.io/openclaw/openclaw:latest}"
SSH_KEY_PATH="${SSH_KEY_PATH:-/home/ubuntu/.ssh/vmdemo_vm}"

log()  { printf '==> %s\n' "$*"; }
warn() { printf 'Warning: %s\n' "$*" >&2; }
die()  { printf 'Error: %s\n' "$*" >&2; exit 1; }

require_cmd() { command -v "$1" >/dev/null 2>&1 || die "Missing command: $1"; }
require_root() { [[ $EUID -eq 0 ]] || die "Run as root"; }

ensure_root_dirs() { mkdir -p "$STATE_ROOT" "$FC_ROOT"; }

validate_instance_id() {
  local id="$1"
  [[ -n "$id" ]] || die "instance id is required"
  [[ "$id" =~ ^[a-z0-9_-]+$ ]] || die "instance id must match [a-z0-9_-]+"
}

validate_host_port() {
  local port="$1"
  [[ "$port" =~ ^[0-9]+$ ]] || die "host port must be numeric"
  port=$((10#$port))
  (( port >= 1 && port <= 65535 )) || die "host port must be in range 1-65535"
}

validate_base_port() {
  [[ "$BASE_PORT" =~ ^[0-9]+$ ]] || die "BASE_PORT must be numeric"
  local base=$((10#$BASE_PORT))
  (( base >= 0 && base < 65535 )) || die "BASE_PORT must be in range 0-65534"
}

validate_ipv4() {
  local ip="$1"
  local label="$2"
  local a b c d extra octet n
  [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || die "invalid $label: $ip"
  IFS='.' read -r a b c d extra <<< "$ip"
  [[ -z "${extra:-}" && -n "${a:-}" && -n "${b:-}" && -n "${c:-}" && -n "${d:-}" ]] || die "invalid $label: $ip"
  for octet in "$a" "$b" "$c" "$d"; do
    [[ "$octet" =~ ^[0-9]+$ ]] || die "invalid $label: $ip"
    n=$((10#$octet))
    (( n >= 0 && n <= 255 )) || die "invalid $label octet: $ip"
  done
}

subnet_mask_bits() {
  local mask="${SUBNET_CIDR#*/}"
  [[ "$mask" =~ ^[0-9]+$ ]] || die "invalid SUBNET_CIDR: $SUBNET_CIDR"
  mask=$((10#$mask))
  (( mask == 24 )) || die "SUBNET_CIDR must use /24 for automatic IP allocation: $SUBNET_CIDR"
  echo "$mask"
}

subnet_prefix() {
  local subnet_ip="${SUBNET_CIDR%/*}"
  validate_ipv4 "$subnet_ip" "SUBNET_CIDR network"
  local prefix="${subnet_ip%.*}"
  local base_octet="${subnet_ip##*.}"
  (( 10#$base_octet == 0 )) || die "SUBNET_CIDR network must end in .0 for /24: $SUBNET_CIDR"
  echo "$prefix"
}

bridge_gateway_ip() {
  local gateway="${BRIDGE_ADDR%/*}"
  local mask="${BRIDGE_ADDR#*/}"
  [[ "$BRIDGE_ADDR" == */* && "$mask" =~ ^[0-9]+$ ]] || die "invalid BRIDGE_ADDR: $BRIDGE_ADDR"
  mask=$((10#$mask))
  (( mask == 24 )) || die "BRIDGE_ADDR must use /24: $BRIDGE_ADDR"
  validate_ipv4 "$gateway" "BRIDGE_ADDR"
  echo "$gateway"
}

instance_dir()      { printf '%s/.vm-%s\n' "$STATE_ROOT" "$1"; }
instance_env()      { printf '%s/.env\n' "$(instance_dir "$1")"; }
instance_token()    { printf '%s/.token\n' "$(instance_dir "$1")"; }
fc_instance_dir()   { printf '%s/%s\n' "$FC_ROOT" "$1"; }
vm_service()        { printf 'firecracker-vmdemo-%s.service\n' "$1"; }
proxy_service()     { printf 'vmdemo-proxy-%s.service\n' "$1"; }
guest_health_script() { printf '/usr/local/bin/openclaw-health-%s.sh\n' "$1"; }

load_instance_env() {
  local id="$1"
  validate_instance_id "$id"
  local f line key value
  f="$(instance_env "$id")"
  [[ -f "$f" ]] || die "instance '$id' not found"
  [[ -r "$f" ]] || die "Cannot read instance state: $f (try: sudo fireclaw ...)"
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -n "$line" && "$line" != \#* ]] || continue
    [[ "$line" == *=* ]] || die "invalid state entry in $f: $line"
    key="${line%%=*}"
    value="${line#*=}"
    case "$key" in
      FIRECLAW_STATE_FORMAT)
        ;;
      INSTANCE_ID|HOST_PORT|VM_IP|VM_TAP|VM_MAC|GATEWAY_TOKEN|MODEL|SKILLS|TELEGRAM_USERS|OPENCLAW_IMAGE|VM_VCPU|VM_MEM_MIB|DISK_SIZE|API_SOCK|SSH_KEY_PATH|SKIP_BROWSER_INSTALL|ANTHROPIC_API_KEY|OPENAI_API_KEY|MINIMAX_API_KEY)
        printf -v "$key" '%s' "$value"
        ;;
      *)
        die "unknown state key in $f: $key"
        ;;
    esac
  done < "$f"
}

_host_port_allocated() {
  local candidate="$1"
  local nullglob_was_set=0 found=1
  shopt -q nullglob && nullglob_was_set=1
  shopt -s nullglob
  local f p
  for f in "$STATE_ROOT"/.vm-*/.env; do
    p="$(grep '^HOST_PORT=' "$f" | cut -d= -f2 || true)"
    if [[ "$p" == "$candidate" ]]; then
      found=0
      break
    fi
  done
  (( nullglob_was_set )) || shopt -u nullglob
  return "$found"
}

_host_port_in_use() {
  local candidate="$1"
  if command -v ss >/dev/null 2>&1; then
    ss -H -ltn "sport = :$candidate" 2>/dev/null | grep -q .
    return $?
  fi
  if command -v lsof >/dev/null 2>&1; then
    lsof -nP -iTCP:"$candidate" -sTCP:LISTEN >/dev/null 2>&1
    return $?
  fi
  warn "neither ss nor lsof found; cannot check if port $candidate is already in use"
  return 1
}

ensure_host_port_available() {
  local candidate="$1"
  validate_host_port "$candidate"
  _host_port_allocated "$candidate" && die "Host port is already assigned to an existing instance: $candidate"
  _host_port_in_use "$candidate" && die "Host port is already in use on this host: $candidate"
  return 0
}

next_port() {
  validate_base_port
  local base candidate
  base=$((10#$BASE_PORT))
  for ((candidate=base + 1; candidate<=65535; candidate++)); do
    if _host_port_allocated "$candidate"; then
      continue
    fi
    if _host_port_in_use "$candidate"; then
      continue
    fi
    echo "$candidate"
    return 0
  done
  die "No available host port found above BASE_PORT=$BASE_PORT"
}

next_ip() {
  local prefix gateway gateway_octet mask
  prefix="$(subnet_prefix)"
  gateway="$(bridge_gateway_ip)"
  mask="$(subnet_mask_bits)"
  [[ "$gateway" == "$prefix".* ]] || die "BRIDGE_ADDR gateway ($gateway) must be in SUBNET_CIDR ($SUBNET_CIDR)"
  gateway_octet="${gateway##*.}"
  gateway_octet=$((10#$gateway_octet))

  local -a used=()
  used["$gateway_octet"]=1

  local nullglob_was_set=0
  shopt -q nullglob && nullglob_was_set=1
  shopt -s nullglob
  local f ip oct
  for f in "$STATE_ROOT"/.vm-*/.env; do
    ip="$(grep '^VM_IP=' "$f" | cut -d= -f2 || true)"
    [[ "$ip" == "$prefix".* ]] || continue
    oct="${ip##*.}"
    [[ "$oct" =~ ^[0-9]+$ ]] || continue
    oct=$((10#$oct))
    (( oct >= 0 && oct <= 255 )) || continue
    used["$oct"]=1
  done

  local candidate chosen=""
  for ((candidate=2; candidate<=254; candidate++)); do
    [[ -n "${used[$candidate]:-}" ]] && continue
    chosen="$prefix.$candidate"
    break
  done
  (( nullglob_was_set )) || shopt -u nullglob

  if [[ -n "$chosen" ]]; then
    echo "$chosen"
    return 0
  fi

  die "IP pool exhausted for subnet $prefix.0/$mask"
}

ensure_bridge_and_nat() {
  if ! ip link show "$BRIDGE_NAME" >/dev/null 2>&1; then
    ip link add "$BRIDGE_NAME" type bridge
  fi
  ip -4 addr show dev "$BRIDGE_NAME" | grep -Fq " $BRIDGE_ADDR " || ip addr add "$BRIDGE_ADDR" dev "$BRIDGE_NAME"
  ip link set "$BRIDGE_NAME" up

  sysctl -w net.ipv4.ip_forward=1 >/dev/null

  iptables -t nat -C POSTROUTING -s "$SUBNET_CIDR" ! -o "$BRIDGE_NAME" -j MASQUERADE 2>/dev/null \
    || iptables -t nat -A POSTROUTING -s "$SUBNET_CIDR" ! -o "$BRIDGE_NAME" -j MASQUERADE
}

wait_for_ssh() {
  local ip="$1"
  local key="${2:-$SSH_KEY_PATH}"
  local retries="${3:-120}"
  local instance_id="${4:-${INSTANCE_ID:-}}"
  local vm_svc=""

  if [[ ! -r "$key" ]]; then
    if [[ $EUID -ne 0 ]]; then
      die "Cannot read SSH key: $key (try: sudo fireclaw ...)"
    else
      die "SSH key not found: $key"
    fi
  fi

  if [[ -n "$instance_id" ]]; then
    vm_svc="$(vm_service "$instance_id")"
  fi

  local vm_state

  local i
  for ((i=1; i<=retries; i++)); do
    if ssh -i "$key" -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null -o ConnectTimeout=3 "ubuntu@$ip" true >/dev/null 2>&1; then
      return 0
    fi
    if [[ -n "$vm_svc" ]]; then
      vm_state="$(systemctl is-active "$vm_svc" 2>/dev/null)" || vm_state="inactive"
      if [[ "$vm_state" != "active" ]]; then
        die "VM is not running ($(printf '\033[31m%s\033[0m' "$vm_state")). Start it with: sudo fireclaw start $instance_id"
      fi
    fi
    sleep 2
  done
  die "VM is running but SSH did not become reachable at ubuntu@$ip after $((retries * 2))s"
}

ssh_reachable() {
  local ip="$1"
  local key="${2:-$SSH_KEY_PATH}"
  [[ -r "$key" ]] || return 1
  ssh -i "$key" -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null -o ConnectTimeout=3 "ubuntu@$ip" true >/dev/null 2>&1
}

check_guest_health() {
  local id="$1"
  local ip="$2"
  local key="${3:-$SSH_KEY_PATH}"
  validate_instance_id "$id"
  local script
  script="$(guest_health_script "$id")"
  ssh -i "$key" -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null -o ConnectTimeout=3 "ubuntu@$ip" "if [[ -x '$script' ]]; then sudo '$script'; else curl -fsS http://127.0.0.1:18789/health >/dev/null; fi" >/dev/null 2>&1
}

wait_for_instance_health() {
  local id="$1"
  local ip="$2"
  local port="$3"
  local key="${4:-$SSH_KEY_PATH}"
  local retries="${5:-30}"
  local host_ok="false"
  local guest_ok="false"

  validate_instance_id "$id"
  validate_host_port "$port"

  local i
  for ((i=1; i<=retries; i++)); do
    host_ok="false"
    guest_ok="false"
    curl -fsS "http://127.0.0.1:$port/health" >/dev/null 2>&1 && host_ok="true"
    if check_guest_health "$id" "$ip" "$key"; then
      guest_ok="true"
    fi
    if [[ "$host_ok" == "true" && "$guest_ok" == "true" ]]; then
      return 0
    fi
    sleep 2
  done

  return 1
}
