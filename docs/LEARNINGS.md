# Fireclaw — Learnings and Follow‑Ups

Date: 2026-02-07

## Key Learnings (from real setup)

1. **Firecracker API socket conflicts**
   - Default Firecracker uses `/run/firecracker.socket`.
   - Multiple VMs collide unless each VM uses a **unique** `--api-sock` path.
   - Fix: generate a per‑instance socket path (e.g. `/srv/firecracker/vm-demo/<id>/firecracker.socket`) and pass `--api-sock` in the VM start script.

2. **Ubuntu cloud rootfs is small by default**
   - `jammy-server-cloudimg-amd64.img` expands to ~1.7GB.
   - Provisioning fails with `No space left on device` during `apt-get`.
   - Fix: `qemu-img resize <rootfs> 40G` and run `resize2fs /dev/vda` inside the VM before provisioning.

3. **Docker inside Firecracker: nftables / iptables issues**
   - `dockerd` fails with: `iptables ... Failed to initialize nft: Protocol not supported`.
   - Fix in guest:
     - `/etc/docker/daemon.json`:
       ```
       {
         "iptables": false,
         "ip6tables": false,
         "bridge": "none"
       }
       ```
     - Run all containers with `--network host`.

4. **OpenClaw auth profiles location**
   - Effective config root is `/home/ubuntu/.openclaw-<id>/config`.
   - Auth must live under:
     ```
     /home/ubuntu/.openclaw-<id>/config/agents/main/agent/auth-profiles.json
     ```

5. **Browser install nuances**
   - `npx playwright install` fails if Playwright isn’t already a dependency.
   - Use the image's Playwright package when present, with a pinned fallback, and **mount** the tools dir so assets land in:
     ```
     /home/ubuntu/openclaw-<id>/tools/.playwright
     ```
   - Then set:
     ```
     browser.executablePath = /home/node/clawd/tools/.playwright/chromium_headless_shell-<ver>/.../chrome-headless-shell
     ```

6. **Health check can return empty reply**
   - Proxy `curl http://127.0.0.1:<port>/health` may return `Empty reply`.
   - When this happens, confirm inside VM:
     - OpenClaw container is running
     - Gateway is listening on `0.0.0.0:18789`
   - Consider using a lightweight in-VM health check (e.g. `curl http://127.0.0.1:18789/health`) and proxy that.

## Follow‑Ups / Improvements to Investigate

1. ~~**Add `--api-sock` support**~~ Done — each VM gets a unique socket.
2. ~~**Add `--disk-size` and auto‑resize logic**~~ Done — `fireclaw setup --disk-size`.
3. ~~**Add apt lock handling**~~ Done — provisioning waits for cloud-init and apt/dpkg locks.
4. ~~**Make Docker config idempotent**~~ Done — provisioning writes daemon.json and restarts Docker only when needed.
5. ~~**Ensure browser install is reliable**~~ Done — browser assets are installed into the mounted tools dir, using the image Playwright package when available.
6. ~~**Verify Telegram enablement**~~ Done — provisioning configures Telegram, applies `doctor --fix`, and rejects empty allowlists.
7. ~~**Better health check**~~ Done — host checks can call the VM-side health script as well as the proxy.

Remaining improvements to consider:

1. Add integration coverage for setup/provision/restart behavior using a disposable VM image.
2. Add a release checklist for package versioning, smoke tests, and npm publish.
3. Consider adding a global setup lock; allocation scans file state and is safe for sequential setup, but concurrent setup can still race before each process writes its chosen `.env`.

## Production hardening validated later

- Explicit `--host-port` now succeeds for free ports and still rejects assigned/listening ports.
- Setup validates persisted values before creating state/assets, so malformed values such as newlines do not leave partial instance directories.
- Setup failure after VM/state creation rolls back the new instance state/assets/units/tap instead of stranding a running VM.
- `setup`, `provision`, and `start` require guest + proxy health before returning success.
- `provision --telegram-users` replaces the saved allowlist value instead of appending duplicate keys.
- Guest `/tmp/provision.vars` and `/tmp/provision-guest.sh` are removed after guest provisioning exits.
- New instance state directories, VM asset directories, saved env files, and provisioned guest rootfs images are root-only on the host.
