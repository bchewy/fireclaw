# fireclaw-vm-demo

Firecracker-based OpenClaw instance manager.

## Prereqs
- firecracker binary at `/usr/local/bin/firecracker`
- `cloud-localds`, `socat`, `jq`, `iptables`, `iproute2`, `ssh`, `scp`
- Base VM assets available (kernel + rootfs [+ initrd])

## First run
```
sudo ./bin/vm-setup --instance vm-demo --telegram-token "<token>" --telegram-users "<your-telegram-user-id>" --model "anthropic/claude-opus-4-6"
```

## Control
```
sudo ./bin/vm-ctl status
sudo ./bin/vm-ctl logs vm-demo
sudo ./bin/vm-ctl logs vm-demo host
sudo ./bin/vm-ctl shell vm-demo
curl -fsS http://127.0.0.1:<HOST_PORT>/health
```
