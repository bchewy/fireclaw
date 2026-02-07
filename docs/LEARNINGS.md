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
   - Use `npx --yes playwright@latest install chromium` and **mount** the tools dir so assets land in:
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
3. **Add apt lock handling** (wait for cloud‑init to release `/var/lib/apt/lists/lock`).
4. **Make Docker config idempotent** in provisioning (write daemon.json + restart docker).
5. **Ensure browser install is reliable**:
   - Use `playwright@latest install chromium`
   - Ensure tools dir is mounted for installs
6. **Verify Telegram enablement**:
   - CLI prints “Telegram configured, not enabled yet.”
   - Consider `openclaw doctor --fix` after config changes.
7. **Better health check**:
   - Add a VM‑side health check script and have the host query it.
