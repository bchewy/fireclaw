---
name: fireclaw-vm-demo
description: Provision, configure, and manage OpenClaw AI agent instances running inside Firecracker microVMs. Use when creating new VM instances, controlling VM lifecycle (start/stop/restart/destroy), debugging guest services, checking instance health, or modifying VM provisioning scripts.
compatibility: Requires Linux host with KVM, firecracker, cloud-localds, socat, jq, iptables, iproute2, ssh, scp, curl, openssl. All commands require root.
metadata:
  author: bchewy
  version: "1.0"
---

# Fireclaw VM Demo

Firecracker microVM control plane for isolated OpenClaw instances. Each instance gets its own VM with separate kernel, filesystem, network, and Docker daemon.

## Architecture

```
Host
├── systemd: firecracker-vmdemo-<id>.service   (Firecracker VM process)
├── systemd: vmdemo-proxy-<id>.service          (socat: localhost:<port> → VM:18789)
├── bridge: fcbr0 (172.16.0.0/24)
│
└── Firecracker VM (172.16.0.x)
    ├── cloud-init → ubuntu user, SSH key, Docker
    ├── Docker → OpenClaw container image
    ├── systemd: openclaw-<id>.service → gateway on port 18789
    └── Browser binaries (Puppeteer + Playwright)
```

State locations:
- Repo-local: `.vm-demo/.vm-<id>/` (env, token, provision vars)
- Host filesystem: `/srv/firecracker/vm-demo/<id>/` (VM images, config, logs)

## Scripts

### bin/vm-setup

One-shot instance creator. Must run as root.

```bash
sudo ./bin/vm-setup \
  --instance <id> \
  --telegram-token "<token>" \
  --telegram-users "<user-ids>" \
  --model "anthropic/claude-opus-4-6" \
  --anthropic-api-key "<key>"
```

Flow: validates inputs → generates SSH key → allocates IP + port → copies rootfs → generates cloud-init seed → writes Firecracker config → creates systemd units → boots VM → waits for SSH → SCPs provision-guest.sh into VM → runs it → enables proxy → polls health.

Options:

| Flag | Default |
|------|---------|
| `--instance` | required, `[a-z0-9_-]+` |
| `--telegram-token` | required |
| `--telegram-users` | comma-separated IDs |
| `--model` | `anthropic/claude-opus-4-6` |
| `--skills` | `github,tmux,coding-agent,session-logs,skill-creator` |
| `--openclaw-image` | `ghcr.io/openclaw/openclaw:latest` |
| `--vm-vcpu` | `4` |
| `--vm-mem-mib` | `8192` |
| `--skip-browser-install` | `false` |

### bin/vm-ctl

Lifecycle management. Most commands require root.

```bash
sudo ./bin/vm-ctl list                    # all instances with health
sudo ./bin/vm-ctl status <id>             # detailed status including guest service
sudo ./bin/vm-ctl start <id>              # boot VM + start guest + enable proxy
sudo ./bin/vm-ctl stop <id>               # graceful shutdown (guest → VM → proxy)
sudo ./bin/vm-ctl restart <id>            # stop then start
sudo ./bin/vm-ctl logs <id>               # tail guest (OpenClaw) logs via SSH
sudo ./bin/vm-ctl logs <id> host          # tail host (Firecracker + proxy) logs
sudo ./bin/vm-ctl shell <id>              # SSH into VM
sudo ./bin/vm-ctl shell <id> "command"    # run command inside VM
sudo ./bin/vm-ctl token <id>              # print gateway token
sudo ./bin/vm-ctl destroy <id>            # interactive destroy
sudo ./bin/vm-ctl destroy <id> --force    # skip confirmation
```

### bin/vm-common.sh

Shared library sourced by all scripts. Provides: path helpers, instance ID validation, IP/port allocation (scans .env files), bridge/NAT setup, SSH wait loop, systemd unit name generators.

### scripts/provision-guest.sh

Runs inside the VM as root. Installs Docker, pulls OpenClaw image, configures via CLI (gateway auth, Telegram bot, model, skills, browser paths), creates and starts guest systemd service.

## Debugging

If an instance is unhealthy:

1. Check host-side services: `sudo ./bin/vm-ctl status <id>` — look at vm/proxy/guest/health fields
2. If VM is active but guest is down: `sudo ./bin/vm-ctl shell <id> "sudo systemctl status openclaw-<id>.service"`
3. Check guest logs: `sudo ./bin/vm-ctl logs <id>`
4. Check host logs: `sudo ./bin/vm-ctl logs <id> host`
5. Check Firecracker log: read `/srv/firecracker/vm-demo/<id>/logs/firecracker.log`
6. If SSH fails: VM may not have booted — check host logs for Firecracker errors
7. Health endpoint: `curl -fsS http://127.0.0.1:<HOST_PORT>/health`

## Environment Overrides

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

## Modifying Scripts

- `vm-common.sh` is sourced by both `vm-setup` and `vm-ctl` — changes there affect everything
- Instance IDs must match `^[a-z0-9_-]+$` — this is enforced by `validate_instance_id`
- IP allocation uses 172.16.0.x where x starts at 2 (gateway is .1), max 254 instances
- Port allocation starts at BASE_PORT+1 and increments per instance
- Guest service name pattern: `openclaw-<id>.service`
- Host VM service pattern: `firecracker-vmdemo-<id>.service`
- Host proxy service pattern: `vmdemo-proxy-<id>.service`
