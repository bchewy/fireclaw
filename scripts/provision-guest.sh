#!/usr/bin/env bash
set -euo pipefail

[[ $# -eq 1 ]] || { echo "Usage: provision-guest.sh <vars-file>" >&2; exit 1; }
VARS_FILE="$1"
[[ -f "$VARS_FILE" ]] || { echo "Vars file missing: $VARS_FILE" >&2; exit 1; }

cleanup_guest_tmp() {
  if [[ "$VARS_FILE" == /tmp/provision.vars ]]; then
    rm -f "$VARS_FILE"
  fi
  rm -f /tmp/provision-guest.sh
}
trap cleanup_guest_tmp EXIT

legacy_unquote_value() {
  local value="$1"
  local out="" ch inner
  if [[ "$value" == "''" ]]; then
    printf ''
    return
  fi
  if [[ "$value" == \$\'*\' && ${#value} -ge 3 ]]; then
    inner="${value:2:${#value}-3}"
    printf '%b' "$inner"
    return
  fi
  while [[ -n "$value" ]]; do
    ch="${value:0:1}"
    if [[ "$ch" == "\\" && ${#value} -gt 1 ]]; then
      value="${value:1}"
      out="${out}${value:0:1}"
    else
      out="${out}${ch}"
    fi
    value="${value:1}"
  done
  printf '%s' "$out"
}

load_vars_file() {
  local format line key value
  format="$(grep '^FIRECLAW_STATE_FORMAT=' "$VARS_FILE" | tail -n 1 | cut -d= -f2- || true)"
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -n "$line" && "$line" != \#* ]] || continue
    [[ "$line" == *=* ]] || { echo "Invalid vars entry in $VARS_FILE: $line" >&2; exit 1; }
    key="${line%%=*}"
    value="${line#*=}"
    if [[ "$key" == "FIRECLAW_STATE_FORMAT" ]]; then
      continue
    fi
    if [[ "$format" != "plain-v1" ]]; then
      value="$(legacy_unquote_value "$value")"
    fi
    [[ "$value" != *$'\n'* && "$value" != *$'\r'* ]] || { echo "Invalid newline in vars value: $key" >&2; exit 1; }
    case "$key" in
      INSTANCE_ID|TELEGRAM_TOKEN|TELEGRAM_USERS|MODEL|SKILLS|GATEWAY_TOKEN|OPENCLAW_IMAGE|SKIP_BROWSER_INSTALL|DISK_SIZE|ANTHROPIC_API_KEY|OPENAI_API_KEY|MINIMAX_API_KEY)
        printf -v "$key" '%s' "$value"
        export "$key"
        ;;
      *)
        echo "Unknown vars key in $VARS_FILE: $key" >&2
        exit 1
        ;;
    esac
  done < "$VARS_FILE"
}

load_vars_file

require() { [[ -n "${!1:-}" ]] || { echo "Missing required var: $1" >&2; exit 1; }; }

require INSTANCE_ID
require MODEL
require SKILLS
require GATEWAY_TOKEN
require OPENCLAW_IMAGE
if [[ -n "${TELEGRAM_TOKEN:-}" ]]; then
  require TELEGRAM_USERS
fi

[[ "$INSTANCE_ID" =~ ^[a-z0-9_-]+$ ]] || {
  echo "INSTANCE_ID must match [a-z0-9_-]+" >&2
  exit 1
}

CONFIG_ROOT="/home/ubuntu/.openclaw-${INSTANCE_ID}"
CONFIG_DIR="$CONFIG_ROOT/config"
WORKSPACE_DIR="/home/ubuntu/openclaw-${INSTANCE_ID}/workspace"
TOOLS_DIR="/home/ubuntu/openclaw-${INSTANCE_ID}/tools"
ENV_FILE="$CONFIG_ROOT/openclaw.env"
GUEST_SERVICE="openclaw-${INSTANCE_ID}.service"
HEALTH_SCRIPT="/usr/local/bin/openclaw-health-${INSTANCE_ID}.sh"
PLAYWRIGHT_FALLBACK_PACKAGE="${PLAYWRIGHT_FALLBACK_PACKAGE:-playwright@1.44.1}"

log()  { printf '==> %s\n' "$*"; }
warn() { printf 'Warning: %s\n' "$*" >&2; }

csv_values() {
  printf '%s' "$1" | tr ',' '\n' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//; /^$/d'
}

csv_json_array() {
  local values
  values="$(csv_values "$1")"
  if [[ -z "$values" ]]; then
    printf '[]\n'
  else
    printf '%s\n' "$values" | jq -R . | jq -s .
  fi
}

wait_for_cloud_init() {
  if command -v cloud-init >/dev/null 2>&1; then
    log "Waiting for cloud-init to finish"
    cloud-init status --wait >/dev/null 2>&1 || warn "cloud-init wait failed; continuing"
  fi
}

wait_for_apt_locks() {
  local timeout="${1:-300}"
  local waited=0
  local lock_files=(
    /var/lib/dpkg/lock-frontend
    /var/lib/dpkg/lock
    /var/lib/apt/lists/lock
    /var/cache/apt/archives/lock
  )

  while true; do
    local locked=0
    if command -v fuser >/dev/null 2>&1; then
      local lock
      for lock in "${lock_files[@]}"; do
        if [[ -e "$lock" ]] && fuser "$lock" >/dev/null 2>&1; then
          locked=1
          break
        fi
      done
    else
      pgrep -f 'apt|dpkg' >/dev/null 2>&1 && locked=1
    fi

    if [[ "$locked" -eq 0 ]]; then
      return 0
    fi

    if (( waited == 0 )); then
      log "Waiting for apt/dpkg locks to clear"
    fi
    sleep 2
    waited=$((waited + 2))
    (( waited < timeout )) || { echo "Timed out waiting for apt locks" >&2; return 1; }
  done
}

apt_get_retry() {
  local attempt
  for attempt in {1..5}; do
    wait_for_apt_locks
    if apt-get "$@"; then
      return 0
    fi
    if (( attempt == 5 )); then
      echo "apt-get $* failed after $attempt attempts" >&2
      return 1
    fi
    warn "apt-get $* failed (attempt $attempt/5), retrying"
    sleep 3
  done
}

maybe_resize_rootfs() {
  command -v resize2fs >/dev/null 2>&1 || { warn "resize2fs not found; skipping rootfs expansion"; return 0; }

  local root_device fs_device fs_type
  root_device="$(findmnt -n -o SOURCE / || true)"
  if [[ "$root_device" == "/dev/root" ]]; then
    root_device="$(readlink -f /dev/root || true)"
  fi

  fs_device=""
  for candidate in "$root_device" /dev/vda; do
    [[ -n "$candidate" && -b "$candidate" ]] || continue
    fs_type="$(blkid -s TYPE -o value "$candidate" 2>/dev/null || true)"
    if [[ "$fs_type" == "ext4" ]]; then
      fs_device="$candidate"
      break
    fi
  done

  if [[ -z "$fs_device" ]]; then
    warn "No ext4 root block device found for resize2fs; skipping"
    return 0
  fi

  log "Expanding ext4 filesystem on $fs_device"
  resize2fs "$fs_device" || warn "resize2fs failed on $fs_device; continuing"
}

ensure_docker_daemon_config() {
  local docker_cfg="/etc/docker/daemon.json"
  local tmp_cfg
  local restart_needed="false"
  tmp_cfg="$(mktemp)"

  cat > "$tmp_cfg" <<'EOF'
{
  "iptables": false,
  "ip6tables": false,
  "bridge": "none"
}
EOF

  mkdir -p /etc/docker
  if [[ ! -f "$docker_cfg" ]] || ! cmp -s "$tmp_cfg" "$docker_cfg"; then
    install -m 0644 "$tmp_cfg" "$docker_cfg"
    restart_needed="true"
  fi
  rm -f "$tmp_cfg"

  systemctl enable docker >/dev/null 2>&1 || true
  if [[ "$restart_needed" == "true" ]]; then
    systemctl restart docker
  elif ! systemctl is-active --quiet docker; then
    systemctl restart docker
  fi
}

export DEBIAN_FRONTEND=noninteractive

wait_for_cloud_init
wait_for_apt_locks
maybe_resize_rootfs

if ! command -v docker >/dev/null 2>&1; then
  apt_get_retry update
  apt_get_retry install -y docker.io jq curl ca-certificates
fi
if ! command -v jq >/dev/null 2>&1 || ! command -v curl >/dev/null 2>&1; then
  apt_get_retry update
  apt_get_retry install -y jq curl ca-certificates
fi
ensure_docker_daemon_config

skills_json="$(csv_json_array "${SKILLS:-}")"

telegram_allow_from_json="[]"
if [[ -n "${TELEGRAM_TOKEN:-}" ]]; then
  telegram_users_values="$(csv_values "${TELEGRAM_USERS:-}")"
  if [[ -z "$telegram_users_values" ]]; then
    echo "TELEGRAM_USERS must include at least one allowed Telegram user ID; refusing to create an unreachable allowlist bot" >&2
    exit 1
  fi
  telegram_allow_from_json="$(printf '%s\n' "$telegram_users_values" | jq -R . | jq -s .)"
fi

mkdir -p "$CONFIG_DIR" "$WORKSPACE_DIR" "$TOOLS_DIR"
chown -R ubuntu:ubuntu "$CONFIG_ROOT" "/home/ubuntu/openclaw-${INSTANCE_ID}"

cat > "$ENV_FILE" <<EOF
NODE_ENV=production
BROWSER=echo
CLAWDBOT_PREFER_PNPM=1
OPENCLAW_PREFER_PNPM=1
PLAYWRIGHT_BROWSERS_PATH=/home/node/clawd/tools/.playwright
OPENCLAW_GATEWAY_TOKEN=$GATEWAY_TOKEN
ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY:-}
OPENAI_API_KEY=${OPENAI_API_KEY:-}
MINIMAX_API_KEY=${MINIMAX_API_KEY:-}
EOF
chmod 600 "$ENV_FILE"

docker pull "$OPENCLAW_IMAGE"

run_openclaw_cli() {
  docker run --rm -i \
    --network host \
    -e HOME=/home/node \
    -e OPENCLAW_GATEWAY_TOKEN="$GATEWAY_TOKEN" \
    -e OPENCLAW_TELEGRAM_TOKEN="${TELEGRAM_TOKEN:-}" \
    -e OPENCLAW_MODEL="$MODEL" \
    -e OPENCLAW_TELEGRAM_ALLOW_FROM_JSON="$telegram_allow_from_json" \
    -e OPENCLAW_SKILLS_JSON="$skills_json" \
    -e OPENCLAW_BROWSER_PATH="${OPENCLAW_BROWSER_PATH:-}" \
    -e OPENCLAW_MINIMAX_PROVIDER_JSON="${OPENCLAW_MINIMAX_PROVIDER_JSON:-}" \
    -e ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-}" \
    -e OPENAI_API_KEY="${OPENAI_API_KEY:-}" \
    -e MINIMAX_API_KEY="${MINIMAX_API_KEY:-}" \
    -v "$CONFIG_DIR:/home/node/.openclaw" \
    -v "$WORKSPACE_DIR:/home/node/.openclaw/workspace" \
    -v "$TOOLS_DIR:/home/node/clawd/tools" \
    --entrypoint /bin/bash \
    "$OPENCLAW_IMAGE" -se
}

run_openclaw_cli <<'EOF'
set -euo pipefail
OPENCLAW='node /app/openclaw.mjs'
$OPENCLAW config set gateway.mode local
$OPENCLAW config set gateway.bind lan
$OPENCLAW config set gateway.auth.mode token
$OPENCLAW config set gateway.auth.token "$OPENCLAW_GATEWAY_TOKEN"
$OPENCLAW config set gateway.tailscale.mode off
$OPENCLAW config set agents.defaults.model.primary "$OPENCLAW_MODEL"
$OPENCLAW config set agents.defaults.skipBootstrap false --json
$OPENCLAW config set skills.allowBundled "$OPENCLAW_SKILLS_JSON" --json
EOF

if [[ -n "${TELEGRAM_TOKEN:-}" ]]; then
  run_openclaw_cli <<'EOF'
set -euo pipefail
OPENCLAW='node /app/openclaw.mjs'
$OPENCLAW config set channels.telegram.enabled true --json
$OPENCLAW config set channels.telegram.botToken "$OPENCLAW_TELEGRAM_TOKEN"
$OPENCLAW config set channels.telegram.dmPolicy allowlist
$OPENCLAW config set channels.telegram.groupPolicy disabled
$OPENCLAW config set channels.telegram.allowFrom "$OPENCLAW_TELEGRAM_ALLOW_FROM_JSON" --json
$OPENCLAW config set plugins.entries.telegram.enabled true --json
EOF
else
  run_openclaw_cli <<'EOF'
set -euo pipefail
OPENCLAW='node /app/openclaw.mjs'
$OPENCLAW config set channels.telegram.enabled false --json
$OPENCLAW config set plugins.entries.telegram.enabled false --json
EOF
fi

if [[ "$MODEL" == minimax/* ]]; then
  OPENCLAW_MINIMAX_PROVIDER_JSON="$(jq -cn --arg api_key "${MINIMAX_API_KEY:-}" '
    {
      baseUrl: "https://api.minimax.io/anthropic",
      apiKey: $api_key,
      api: "anthropic-messages",
      models: [
        {
          id: "MiniMax-M2.1",
          name: "MiniMax M2.1",
          reasoning: false,
          input: ["text"],
          contextWindow: 200000,
          maxTokens: 8192
        }
      ]
    }
  ')"
  run_openclaw_cli <<'EOF'
OPENCLAW='node /app/openclaw.mjs'
$OPENCLAW config set models.mode merge
$OPENCLAW config set models.providers.minimax "$OPENCLAW_MINIMAX_PROVIDER_JSON" --json
EOF
fi

if [[ "${SKIP_BROWSER_INSTALL:-false}" != "true" ]]; then
  docker run --rm -i \
    --network host \
    -e HOME=/home/node \
    -e PLAYWRIGHT_BROWSERS_PATH=/home/node/clawd/tools/.playwright \
    -e PLAYWRIGHT_FALLBACK_PACKAGE="$PLAYWRIGHT_FALLBACK_PACKAGE" \
    -v "$TOOLS_DIR:/home/node/clawd/tools" \
    --entrypoint /bin/bash \
    "$OPENCLAW_IMAGE" -se <<'EOF'
set -euo pipefail

if playwright_cli="$(node <<'NODE'
const path = require("path");
try {
  const pkg = require.resolve("playwright/package.json");
  process.stdout.write(path.join(path.dirname(pkg), "cli.js"));
} catch {
  process.exit(1);
}
NODE
)"; then
  echo "Using Playwright from image: $playwright_cli"
  node "$playwright_cli" install chromium
else
  echo "Using fallback Playwright package: $PLAYWRIGHT_FALLBACK_PACKAGE"
  npx --yes "$PLAYWRIGHT_FALLBACK_PACKAGE" install chromium
fi
EOF

  chrome_host_path="$(
    find "$TOOLS_DIR/.playwright" -type f \
      \( -path '*/chromium_headless_shell-*/chrome-headless-shell' -o -name 'chrome-headless-shell' -o -name 'headless_shell' \) \
      | sort | head -n 1 || true
  )"
  if [[ -n "$chrome_host_path" ]]; then
    chrome_container_path="${chrome_host_path/#$TOOLS_DIR/\/home\/node\/clawd\/tools}"
    OPENCLAW_BROWSER_PATH="$chrome_container_path"
    run_openclaw_cli <<'EOF'
OPENCLAW='node /app/openclaw.mjs'
$OPENCLAW config set browser.executablePath "$OPENCLAW_BROWSER_PATH"
EOF
  else
    warn "Playwright Chromium installed but executable path was not found in $TOOLS_DIR/.playwright"
  fi
fi

run_openclaw_cli <<'EOF'
set -euo pipefail
OPENCLAW='node /app/openclaw.mjs'
$OPENCLAW doctor --fix || true
EOF

cat > "$HEALTH_SCRIPT" <<EOF
#!/usr/bin/env bash
set -euo pipefail

CONTAINER_NAME="openclaw-${INSTANCE_ID}"

if ! /usr/bin/docker inspect -f '{{.State.Running}}' "\$CONTAINER_NAME" 2>/dev/null | grep -qx true; then
  exit 1
fi

curl -fsS http://127.0.0.1:18789/health >/dev/null
EOF
chmod 755 "$HEALTH_SCRIPT"

cat > "/etc/systemd/system/$GUEST_SERVICE" <<EOF
[Unit]
Description=OpenClaw ($INSTANCE_ID)
After=docker.service network-online.target
Requires=docker.service

[Service]
Type=simple
ExecStartPre=-/usr/bin/docker rm -f openclaw-$INSTANCE_ID
ExecStart=/usr/bin/docker run --rm --name openclaw-$INSTANCE_ID --init --network host --env-file $ENV_FILE -e HOME=/home/node -v $CONFIG_DIR:/home/node/.openclaw -v $WORKSPACE_DIR:/home/node/.openclaw/workspace -v $TOOLS_DIR:/home/node/clawd/tools $OPENCLAW_IMAGE node dist/index.js gateway --bind lan --port 18789
ExecStop=/usr/bin/docker stop openclaw-$INSTANCE_ID
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable "$GUEST_SERVICE"
systemctl restart "$GUEST_SERVICE"

echo "Guest provisioning complete for $INSTANCE_ID"
