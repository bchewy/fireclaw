# fireclaw-vm-demo

Run [OpenClaw](https://github.com/openclaw/openclaw) instances inside Firecracker microVMs, each fully isolated with its own filesystem, network, and process tree.

## Why

Running OpenClaw directly on a host (bare metal or in Docker) means every instance shares the kernel, network namespace, and often the Docker socket. That's fine for a single bot, but problematic when you want:

- **Isolation** — one misbehaving instance can't interfere with others or the host
- **Reproducibility** — each VM boots from a clean rootfs image, no drift
- **Security** — no Docker socket mount into the container; the guest runs its own Docker daemon
- **Density** — Firecracker VMs boot in ~125ms and use ~5MB overhead per VM, so you can pack many instances on a single host

This repo is a minimal control plane that wires up Firecracker VM lifecycle, networking, and OpenClaw provisioning with plain bash and systemd. No orchestrator, no Kubernetes, no extra daemons.

## How it works

```
Host
├── systemd: firecracker-vmdemo-<id>.service   ← runs the VM
├── systemd: vmdemo-proxy-<id>.service          ← socat: localhost:<port> → VM:18789
├── bridge: fcbr0 (172.16.0.0/24)              ← shared bridge for all VMs
│
└── Firecracker VM (172.16.0.x)
    ├── cloud-init: ubuntu user, SSH key, Docker install
    ├── Docker: pulls OpenClaw image
    ├── systemd: openclaw-<id>.service          ← docker run ... gateway --bind lan --port 18789
    └── Browser binaries (Puppeteer + Playwright, installed at provision time)
```

1. **`vm-setup`** creates a new instance: copies the base rootfs, generates a cloud-init seed image, allocates an IP + host port, writes a Firecracker config, creates systemd units, boots the VM, waits for SSH, then SCPs `provision-guest.sh` into the guest and runs it.

2. **`provision-guest.sh`** runs inside the VM as root: installs Docker, pulls the OpenClaw image, runs the OpenClaw CLI to configure gateway auth, Telegram bot, model selection, skills, and browser paths, then creates and starts the guest systemd service.

3. **`vm-ctl`** manages the lifecycle after setup: start/stop/restart VMs, tail logs (guest or host side), open an SSH shell, show status, or destroy an instance.

All state lives in two places:
- **Repo-local** `.vm-demo/.vm-<id>/` — env file, token, provision vars
- **Host filesystem** `/srv/firecracker/vm-demo/<id>/` — VM images, Firecracker config, logs

## Prerequisites

- Linux host with KVM support (`/dev/kvm` accessible)
- `firecracker` binary at `/usr/local/bin/firecracker` ([install guide](https://github.com/firecracker-microvm/firecracker/blob/main/docs/getting-started.md))
- `cloud-localds` (from `cloud-image-utils`), `socat`, `jq`, `iptables`, `iproute2`, `ssh`, `scp`, `curl`, `openssl`
- Base VM images: a Linux kernel (`vmlinux`) and an ext4 rootfs with cloud-init support. Optionally an initrd.

Set `BASE_IMAGES_DIR` or pass `--base-kernel`/`--base-rootfs`/`--base-initrd` to point at your images.

## Setup

```bash
# 1. Clone
git clone https://github.com/bchewy/fireclaw-vm-demo.git
cd fireclaw-vm-demo

# 2. Create an instance
sudo ./bin/vm-setup \
  --instance my-bot \
  --telegram-token "<your-bot-token>" \
  --telegram-users "<your-telegram-user-id>" \
  --model "openai/gpt-5.4" \
  --openai-api-key "<key>"

# vm-setup will:
#   - generate an SSH keypair (if needed)
#   - copy + configure the rootfs
#   - boot the VM via systemd
#   - wait for SSH
#   - provision OpenClaw inside the guest
#   - start the localhost proxy
#   - print the instance details (IP, port, token)
```

### Options

| Flag | Default | Description |
|------|---------|-------------|
| `--instance` | (required) | Instance ID (`[a-z0-9_-]+`) |
| `--telegram-token` | (required) | Telegram bot token |
| `--telegram-users` | | Comma-separated Telegram user IDs for allowlist |
| `--model` | `openai/gpt-5.4` | Model ID |
| `--skills` | `github,tmux,coding-agent,session-logs,skill-creator` | Comma-separated skill list |
| `--openclaw-image` | `ghcr.io/openclaw/openclaw:latest` | Docker image for OpenClaw |
| `--vm-vcpu` | `4` | vCPUs per VM |
| `--vm-mem-mib` | `8192` | Memory per VM (MiB) |
| `--anthropic-api-key` | | Anthropic API key |
| `--openai-api-key` | | OpenAI API key |
| `--minimax-api-key` | | MiniMax API key |
| `--skip-browser-install` | `false` | Skip Puppeteer/Playwright install |

## Usage

```bash
# List all instances
sudo ./bin/vm-ctl list

# Status of one instance
sudo ./bin/vm-ctl status my-bot

# Stop / start / restart
sudo ./bin/vm-ctl stop my-bot
sudo ./bin/vm-ctl start my-bot
sudo ./bin/vm-ctl restart my-bot

# Tail guest logs (OpenClaw service)
sudo ./bin/vm-ctl logs my-bot

# Tail host logs (Firecracker + proxy)
sudo ./bin/vm-ctl logs my-bot host

# SSH into the VM
sudo ./bin/vm-ctl shell my-bot

# Run a command inside the VM
sudo ./bin/vm-ctl shell my-bot "docker ps"

# Get the gateway token
sudo ./bin/vm-ctl token my-bot

# Health check
curl -fsS http://127.0.0.1:<HOST_PORT>/health

# Destroy (interactive confirmation)
sudo ./bin/vm-ctl destroy my-bot

# Destroy (skip confirmation)
sudo ./bin/vm-ctl destroy my-bot --force
```

## Networking

Each VM gets a static IP on a bridge (`fcbr0`, `172.16.0.0/24`). The host acts as the gateway at `172.16.0.1` with NAT for outbound traffic. A `socat` proxy on the host forwards `127.0.0.1:<HOST_PORT>` to the VM's gateway port (`18789`), so the OpenClaw API is only reachable from localhost.

## Environment variables

All scripts respect these overrides:

| Variable | Default |
|----------|---------|
| `STATE_ROOT` | `<repo>/.vm-demo` |
| `FC_ROOT` | `/srv/firecracker/vm-demo` |
| `BASE_PORT` | `18890` |
| `BRIDGE_NAME` | `fcbr0` |
| `BRIDGE_ADDR` | `172.16.0.1/24` |
| `SUBNET_CIDR` | `172.16.0.0/24` |
| `SSH_KEY_PATH` | `~/.ssh/vmdemo_vm` |
| `BASE_IMAGES_DIR` | `/srv/firecracker/base/images` |
