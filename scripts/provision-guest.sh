#!/usr/bin/env bash
set -euo pipefail

[[ $# -eq 1 ]] || { echo "Usage: provision-guest.sh <vars-file>" >&2; exit 1; }
VARS_FILE="$1"
[[ -f "$VARS_FILE" ]] || { echo "Vars file missing: $VARS_FILE" >&2; exit 1; }

set -a
source "$VARS_FILE"
set +a

require() { [[ -n "${!1:-}" ]] || { echo "Missing required var: $1" >&2; exit 1; }; }

require INSTANCE_ID
require TELEGRAM_TOKEN
require MODEL
require SKILLS
require GATEWAY_TOKEN
require OPENCLAW_IMAGE

CONFIG_ROOT="/home/ubuntu/.openclaw-${INSTANCE_ID}"
CONFIG_DIR="$CONFIG_ROOT/config"
WORKSPACE_DIR="/home/ubuntu/openclaw-${INSTANCE_ID}/workspace"
TOOLS_DIR="/home/ubuntu/openclaw-${INSTANCE_ID}/tools"
ENV_FILE="$CONFIG_ROOT/openclaw.env"
GUEST_SERVICE="openclaw-${INSTANCE_ID}.service"

export DEBIAN_FRONTEND=noninteractive

if ! command -v docker >/dev/null 2>&1; then
  apt-get update -y
  apt-get install -y docker.io jq curl ca-certificates
fi
systemctl enable docker
systemctl restart docker

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
  local script="$1"
  docker run --rm -T \
    -e HOME=/home/node \
    -e OPENCLAW_GATEWAY_TOKEN="$GATEWAY_TOKEN" \
    -e ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-}" \
    -e OPENAI_API_KEY="${OPENAI_API_KEY:-}" \
    -e MINIMAX_API_KEY="${MINIMAX_API_KEY:-}" \
    -v "$CONFIG_DIR:/home/node/.openclaw" \
    -v "$WORKSPACE_DIR:/home/node/.openclaw/workspace" \
    -v "$TOOLS_DIR:/home/node/clawd/tools" \
    --entrypoint /bin/bash \
    "$OPENCLAW_IMAGE" -lc "$script"
}

skills_json="[]"
IFS=',' read -r -a skills_arr <<< "${SKILLS:-}"
if (( ${#skills_arr[@]} > 0 )); then
  skills_json="$(printf '%s\n' "${skills_arr[@]}" | sed '/^$/d' | jq -R . | jq -s .)"
fi

telegram_allow_from_json="[]"
IFS=',' read -r -a users_arr <<< "${TELEGRAM_USERS:-}"
if (( ${#users_arr[@]} > 0 )); then
  telegram_allow_from_json="$(printf '%s\n' "${users_arr[@]}" | sed '/^$/d' | jq -R . | jq -s .)"
fi

run_openclaw_cli "
set -e
OPENCLAW='node /app/openclaw.mjs'
\$OPENCLAW config set gateway.mode local
\$OPENCLAW config set gateway.bind lan
\$OPENCLAW config set gateway.auth.mode token
\$OPENCLAW config set gateway.auth.token '$GATEWAY_TOKEN'
\$OPENCLAW config set gateway.tailscale.mode off
\$OPENCLAW config set agents.defaults.model.primary '$MODEL'
\$OPENCLAW config set agents.defaults.skipBootstrap false --json
\$OPENCLAW config set channels.telegram.enabled true --json
\$OPENCLAW config set channels.telegram.botToken '$TELEGRAM_TOKEN'
\$OPENCLAW config set channels.telegram.dmPolicy allowlist
\$OPENCLAW config set channels.telegram.groupPolicy disabled
\$OPENCLAW config set channels.telegram.allowFrom '$telegram_allow_from_json' --json
\$OPENCLAW config set plugins.entries.telegram.enabled true --json
\$OPENCLAW config set skills.allowBundled '$skills_json' --json
"

if [[ "$MODEL" == minimax/* ]]; then
  run_openclaw_cli "
  OPENCLAW='node /app/openclaw.mjs'
  \$OPENCLAW config set models.mode merge
  \$OPENCLAW config set models.providers.minimax '{
    \"baseUrl\":\"https://api.minimax.io/anthropic\",
    \"apiKey\":\"${MINIMAX_API_KEY:-}\",
    \"api\":\"anthropic-messages\",
    \"models\":[{\"id\":\"MiniMax-M2.1\",\"name\":\"MiniMax M2.1\",\"reasoning\":false,\"input\":[\"text\"],\"contextWindow\":200000,\"maxTokens\":8192}]
  }' --json
  "
fi

if [[ "${SKIP_BROWSER_INSTALL:-false}" != "true" ]]; then
  docker run --rm -T \
    -e PLAYWRIGHT_BROWSERS_PATH=/home/node/clawd/tools/.playwright \
    -e PUPPETEER_CACHE_DIR=/home/node/clawd/tools/.puppeteer-cache \
    -v "$TOOLS_DIR:/home/node/clawd/tools" \
    --entrypoint /bin/bash \
    "$OPENCLAW_IMAGE" -lc "
      set -e
      npx --yes @puppeteer/browsers install chrome-headless-shell@stable || true
      npx --yes playwright install chromium || true
    "

  chrome_host_path="$(find "$TOOLS_DIR/.puppeteer-cache" -type f -name chrome-headless-shell | head -n 1 || true)"
  if [[ -n "$chrome_host_path" ]]; then
    chrome_container_path="${chrome_host_path/#$TOOLS_DIR/\/home\/node\/clawd\/tools}"
    run_openclaw_cli "
    OPENCLAW='node /app/openclaw.mjs'
    \$OPENCLAW config set browser.executablePath '$chrome_container_path'
    "
  fi
fi

cat > "/etc/systemd/system/$GUEST_SERVICE" <<EOF
[Unit]
Description=OpenClaw ($INSTANCE_ID)
After=docker.service network-online.target
Requires=docker.service

[Service]
Type=simple
ExecStartPre=-/usr/bin/docker rm -f openclaw-$INSTANCE_ID
ExecStart=/usr/bin/docker run --rm --name openclaw-$INSTANCE_ID --init --env-file $ENV_FILE -v $CONFIG_DIR:/home/node/.openclaw -v $WORKSPACE_DIR:/home/node/.openclaw/workspace -v $TOOLS_DIR:/home/node/clawd/tools $OPENCLAW_IMAGE node dist/index.js gateway --bind lan --port 18789
ExecStop=/usr/bin/docker stop openclaw-$INSTANCE_ID
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now "$GUEST_SERVICE"

echo "Guest provisioning complete for $INSTANCE_ID"
