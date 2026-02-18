# fireclaw

Run [OpenClaw](https://github.com/openclaw/openclaw) instances inside Firecracker microVMs with per-instance isolation (filesystem, process tree, and virtual network).

`fireclaw` is intentionally small: a Bash CLI that drives Firecracker + systemd without adding Kubernetes or an always-on control-plane daemon.

## Table of contents

- [What you get](#what-you-get)
- [How it works](#how-it-works)
- [Prerequisites](#prerequisites)
- [Install](#install)
- [Quick start](#quick-start)
- [Command reference](#command-reference)
- [Setup flags](#setup-flags)
- [Networking and allocation](#networking-and-allocation)
- [State layout](#state-layout)
- [Environment variable overrides](#environment-variable-overrides)
- [Operations playbook](#operations-playbook)
- [Troubleshooting](#troubleshooting)
- [Development](#development)
- [Security model](#security-model)

## What you get

- VM-level isolation for each OpenClaw instance.
- Fast lifecycle control with host systemd units.
- Localhost-only gateway exposure via `socat` proxy.
- One-shot provisioning (`setup`) plus repeatable guest reprovisioning (`provision`).
- File-based state that is easy to inspect and recover.

## How it works

```text
Host
├── fireclaw CLI (bash)
├── systemd: firecracker-vmdemo-<id>.service
├── systemd: vmdemo-proxy-<id>.service
├── bridge + NAT: fc-br0 + iptables
└── Firecracker VM (<vm-ip>)
    ├── cloud-init (user + ssh + base packages)
    ├── docker daemon (firecracker-safe network settings)
    └── systemd: openclaw-<id>.service
```

`fireclaw setup` flow:

1. Validate inputs and host dependencies.
2. Allocate a host port and guest IP (or use explicit `--host-port`).
3. Copy and optionally resize rootfs.
4. Generate cloud-init seed + Firecracker config.
5. Create host systemd units (VM + localhost proxy).
6. Boot VM and wait for SSH.
7. Copy and run guest provisioning script.
8. Enable proxy and run host/guest health checks.

`fireclaw provision <id>` flow:

1. Reuse saved instance config (`provision.vars`).
2. Wait for VM SSH reachability.
3. Re-run guest provisioning script.
4. Re-enable proxy and verify health.

## Prerequisites

Host:

- Linux with KVM (`/dev/kvm` available).
- Root/sudo access for lifecycle and networking operations.
- `firecracker` at `/usr/local/bin/firecracker`.
- `cloud-localds`, `qemu-img`, `iptables`, `ip`, `socat`, `jq`, `curl`, `openssl`, `ssh`, `scp`, `systemctl`.

Base images:

- Kernel image (`vmlinux`).
- ext4 rootfs with cloud-init support.
- Optional initrd.

Default base image directory is `/srv/firecracker/base/images`.

## Install

```bash
npm install -g fireclaw
```

## Quick start

```bash
sudo fireclaw setup \
  --instance my-bot \
  --telegram-token "<telegram-bot-token>" \
  --telegram-users "<comma-separated-user-ids>" \
  --model "openai/gpt-5.4" \
  --openai-api-key "<key>"
```

Check status and health:

```bash
sudo fireclaw status my-bot
curl -fsS http://127.0.0.1:<HOST_PORT>/health
```

## Command reference

```bash
fireclaw setup <flags...>
fireclaw provision <id>
fireclaw list
fireclaw status [id]
fireclaw start <id>
fireclaw stop <id>
fireclaw restart <id>
fireclaw logs <id> [guest|host]
fireclaw shell <id> [command...]
fireclaw token <id>
fireclaw destroy <id> [--force]
```

Common lifecycle examples:

```bash
sudo fireclaw list
sudo fireclaw status my-bot
sudo fireclaw logs my-bot guest
sudo fireclaw logs my-bot host
sudo fireclaw shell my-bot
sudo fireclaw shell my-bot "docker ps"
sudo fireclaw token my-bot
sudo fireclaw restart my-bot
sudo fireclaw destroy my-bot --force
```

Reprovision an existing VM guest:

```bash
sudo fireclaw provision my-bot
```

## Setup flags

| Flag | Required | Default | Description |
|------|----------|---------|-------------|
| `--instance <id>` | yes | - | Instance ID (`[a-z0-9_-]+`) |
| `--telegram-token <token>` | yes | - | Telegram bot token |
| `--telegram-users <csv>` | no | empty | Allowed Telegram user IDs |
| `--model <id>` | no | `openai/gpt-5.4` | OpenClaw model |
| `--skills <csv>` | no | `github,tmux,coding-agent,session-logs,skill-creator` | Skill set |
| `--openclaw-image <image>` | no | `ghcr.io/openclaw/openclaw:latest` | OpenClaw container image |
| `--host-port <n>` | no | first free port above `BASE_PORT` | Host localhost proxy port |
| `--vm-vcpu <n>` | no | `4` | VM vCPU count |
| `--vm-mem-mib <n>` | no | `8192` | VM memory in MiB |
| `--disk-size <size>` | no | `40G` | Rootfs resize target |
| `--api-sock <path>` | no | `<fc-instance-dir>/firecracker.socket` | Firecracker API socket path |
| `--base-kernel <path>` | no | `<BASE_IMAGES_DIR>/vmlinux` | Kernel path |
| `--base-rootfs <path>` | no | `<BASE_IMAGES_DIR>/rootfs.ext4` | Rootfs path |
| `--base-initrd <path>` | no | `<BASE_IMAGES_DIR>/initrd.img` | Optional initrd path |
| `--anthropic-api-key <key>` | no | empty | Anthropic key |
| `--openai-api-key <key>` | no | empty | OpenAI key |
| `--minimax-api-key <key>` | no | empty | MiniMax key |
| `--skip-browser-install` | no | `false` | Skip Playwright Chromium installation |

## Networking and allocation

Defaults:

- Bridge: `fc-br0`
- Bridge address: `172.16.0.1/24`
- VM subnet: `172.16.0.0/24`
- OpenClaw gateway in guest: `:18789`
- First auto host port (default): `18891` (`BASE_PORT + 1`)

Allocation behavior:

- Host port auto-allocation chooses the first free port above `BASE_PORT`.
- Auto-allocation skips ports already assigned to existing instances.
- Auto-allocation also skips currently-listening host ports (via `ss`/`lsof` when available).
- VM IP allocation is derived from `SUBNET_CIDR` and reserves the bridge gateway IP from `BRIDGE_ADDR`.
- Current automatic IP allocator requires `/24` subnets.

Access model:

- Guest service listens inside VM on `0.0.0.0:18789`.
- Host proxy binds `127.0.0.1:<HOST_PORT>` and forwards to `<VM_IP>:18789`.
- API remains localhost-only unless you deliberately expose it elsewhere.

## State layout

Per-instance control state:

- `/var/lib/fireclaw/.vm-<id>/.env`
- `/var/lib/fireclaw/.vm-<id>/.token`
- `/var/lib/fireclaw/.vm-<id>/provision.vars`

Firecracker runtime assets:

- `/srv/firecracker/vm-demo/<id>/images/`
- `/srv/firecracker/vm-demo/<id>/config/`
- `/srv/firecracker/vm-demo/<id>/logs/`
- `/srv/firecracker/vm-demo/<id>/start-vm.sh`
- `/srv/firecracker/vm-demo/<id>/stop-vm.sh`

Host unit files:

- `/etc/systemd/system/firecracker-vmdemo-<id>.service`
- `/etc/systemd/system/vmdemo-proxy-<id>.service`

## Environment variable overrides

| Variable | Default | Notes |
|----------|---------|-------|
| `STATE_ROOT` | `/var/lib/fireclaw` | Per-instance state root |
| `FC_ROOT` | `/srv/firecracker/vm-demo` | Firecracker runtime root |
| `BASE_PORT` | `18890` | Auto host-port base |
| `BRIDGE_NAME` | `fc-br0` | Linux bridge name |
| `BRIDGE_ADDR` | `172.16.0.1/24` | Bridge/gateway address |
| `SUBNET_CIDR` | `172.16.0.0/24` | VM subnet (`/24` for auto IP alloc) |
| `SSH_KEY_PATH` | `/home/ubuntu/.ssh/vmdemo_vm` | SSH key for VM access |
| `BASE_IMAGES_DIR` | `/srv/firecracker/base/images` | Kernel/rootfs/initrd base dir |
| `DISK_SIZE` | `40G` | Default setup disk target |
| `API_SOCK` | `<fc-instance-dir>/firecracker.socket` | Default per-instance API socket |
| `OPENCLAW_IMAGE_DEFAULT` | `ghcr.io/openclaw/openclaw:latest` | Default OpenClaw image |

## Operations playbook

Inspect fleet:

```bash
sudo fireclaw list
sudo fireclaw status
```

Tail logs:

```bash
sudo fireclaw logs my-bot guest
sudo fireclaw logs my-bot host
```

Run guest command:

```bash
sudo fireclaw shell my-bot "sudo systemctl status openclaw-my-bot.service"
```

Rotate by reprovisioning:

```bash
sudo fireclaw stop my-bot
sudo fireclaw start my-bot
sudo fireclaw provision my-bot
```

## Troubleshooting

VM does not start:

- Check host unit logs: `sudo journalctl -u firecracker-vmdemo-<id>.service -xe`
- Validate KVM and Firecracker binary path.
- Ensure API socket path is unique and writable.

SSH never becomes reachable:

- Check VM state: `sudo fireclaw status <id>`
- Inspect cloud-init in guest via serial/log output.
- Confirm SSH key path and permissions.

Proxy health fails:

- Host side: `curl -v http://127.0.0.1:<port>/health`
- Guest side: `sudo fireclaw shell <id> "curl -fsS http://127.0.0.1:18789/health"`
- Confirm `openclaw-<id>.service` is active in guest.

Disk pressure during provisioning:

- Increase `--disk-size`.
- Re-run provisioning with `sudo fireclaw provision <id>`.

## Development

From repo root:

```bash
npm test
npm run lint:shell
npm run test:unit
npm run pack:check
```

What they do:

- `npm run lint:shell`: syntax-checks all shipped shell scripts and test scripts.
- `npm run test:unit`: runs unit tests for reusable shell helpers (`bin/vm-common.sh`).
- `npm run pack:check`: validates npm package content (`npm pack --dry-run`).

Contribution expectations:

- Keep `bin/fireclaw`, `bin/vm-setup`, and `bin/vm-ctl` usage/help text in sync with behavior.
- Update docs for all user-visible flag/default/flow changes.
- Run `npm test` before handoff.

## Security model

- Strong isolation boundary is the VM, not a container namespace.
- No host Docker socket mount into guest containers.
- API is exposed through localhost proxy by default, reducing remote attack surface.
- Secrets are stored per instance under `STATE_ROOT`; secure host filesystem and limit access.
