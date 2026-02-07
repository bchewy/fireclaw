#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
STATE_ROOT="${STATE_ROOT:-$REPO_ROOT/.vm-demo}"
FC_ROOT="${FC_ROOT:-/srv/firecracker/vm-demo}"
BASE_PORT="${BASE_PORT:-18890}"

BRIDGE_NAME="${BRIDGE_NAME:-fcbr0}"
BRIDGE_ADDR="${BRIDGE_ADDR:-172.16.0.1/24}"
SUBNET_CIDR="${SUBNET_CIDR:-172.16.0.0/24}"

OPENCLAW_IMAGE_DEFAULT="${OPENCLAW_IMAGE_DEFAULT:-ghcr.io/openclaw/openclaw:latest}"
SSH_KEY_PATH="${SSH_KEY_PATH:-$HOME/.ssh/vmdemo_vm}"

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
  local f
  f="$(instance_env "$id")"
  [[ -f "$f" ]] || die "instance '$id' not found"
  set -a
  source "$f"
  set +a
}

next_port() {
  local max="$BASE_PORT"
  shopt -s nullglob
  local f p
  for f in "$STATE_ROOT"/.vm-*/.env; do
    p="$(grep '^HOST_PORT=' "$f" | cut -d= -f2 || true)"
    if [[ -n "${p:-}" && "$p" -gt "$max" ]]; then
      max="$p"
    fi
  done
  shopt -u nullglob
  echo $((max + 1))
}

next_ip() {
  local max_octet=1
  shopt -s nullglob
  local f ip oct
  for f in "$STATE_ROOT"/.vm-*/.env; do
    ip="$(grep '^VM_IP=' "$f" | cut -d= -f2 || true)"
    oct="${ip##*.}"
    if [[ "$oct" =~ ^[0-9]+$ ]] && (( oct > max_octet )); then
      max_octet="$oct"
    fi
  done
  shopt -u nullglob

  local next=$((max_octet + 1))
  (( next < 255 )) || die "IP pool exhausted"
  echo "172.16.0.$next"
}

ensure_bridge_and_nat() {
  if ! ip link show "$BRIDGE_NAME" >/dev/null 2>&1; then
    ip link add "$BRIDGE_NAME" type bridge
  fi
  ip addr add "$BRIDGE_ADDR" dev "$BRIDGE_NAME" 2>/dev/null || true
  ip link set "$BRIDGE_NAME" up

  sysctl -w net.ipv4.ip_forward=1 >/dev/null

  iptables -t nat -C POSTROUTING -s "$SUBNET_CIDR" ! -o "$BRIDGE_NAME" -j MASQUERADE 2>/dev/null \
    || iptables -t nat -A POSTROUTING -s "$SUBNET_CIDR" ! -o "$BRIDGE_NAME" -j MASQUERADE
}

wait_for_ssh() {
  local ip="$1"
  local key="${2:-$SSH_KEY_PATH}"
  local retries="${3:-120}"
  local i
  for ((i=1; i<=retries; i++)); do
    if ssh -i "$key" -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null -o ConnectTimeout=3 "ubuntu@$ip" true >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done
  return 1
}

check_guest_health() {
  local id="$1"
  local ip="$2"
  local key="${3:-$SSH_KEY_PATH}"
  local script
  script="$(guest_health_script "$id")"
  ssh -i "$key" -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null -o ConnectTimeout=3 "ubuntu@$ip" "if [[ -x '$script' ]]; then sudo '$script'; else curl -fsS http://127.0.0.1:18789/health >/dev/null; fi" >/dev/null 2>&1
}
