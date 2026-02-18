# AGENTS.md

Repository guide for coding agents and contributors working in `fireclaw`.

## 1) Documentation Status (Current)

As of 2026-02-08, documentation is in a good state for operators, with a few contributor-focused gaps.

Present and useful:
- `README.md`: architecture, prerequisites, install, setup options, lifecycle usage, networking, env overrides.
- `docs/LEARNINGS.md`: real-world operational learnings and follow-up ideas.
- `llms.txt`: concise technical map of internals and design decisions.

Gaps to keep in mind:
- No dedicated contributor workflow doc (this file fills that gap).
- No explicit release checklist/versioning workflow.
- No automated integration tests (unit tests exist for shell helpers, but no end-to-end VM tests).

## 2) Repo Map

Core files and responsibilities:
- `bin/fireclaw`: CLI entrypoint and command routing.
- `bin/vm-setup`: one-shot provisioning path (`fireclaw setup`).
- `bin/vm-provision`: reprovision-only flow (`fireclaw provision`).
- `bin/vm-ctl`: lifecycle commands (`list/status/start/stop/restart/logs/shell/token/destroy`).
- `bin/vm-common.sh`: shared helpers, path conventions, validation, network/IP/port helpers.
- `scripts/provision-guest.sh`: in-VM provisioning and guest service creation.
- `docs/LEARNINGS.md`: field notes and follow-ups.

## 3) Local Development Commands

Use these from repo root:

```bash
npm test
npm run lint:shell
npm run pack:check
```

What they do:
- `npm test`: runs shell syntax lint (`lint:shell`) and unit tests (`test:unit`).
- `npm run lint:shell`: syntax-checks all shipped shell scripts and test scripts.
- `npm run test:unit`: runs unit tests for reusable shell helpers (`bin/vm-common.sh`).
- `npm run pack:check`: validates npm package contents via `npm pack --dry-run`.

## 4) Runtime and Safety Constraints

- `fireclaw` lifecycle/provisioning commands are designed for Linux hosts and generally require root.
- Provisioning expects host dependencies like `firecracker`, `cloud-localds`, `qemu-img`, `iptables`, `socat`, `ssh/scp`.
- Avoid running destructive instance commands (`destroy`, deleting state under `/var/lib/fireclaw` or `/srv/firecracker/vm-demo`) unless explicitly requested.

## 5) Change Rules for Agents

When changing CLI behavior:
- Keep `bin/fireclaw`, `bin/vm-setup`, and `bin/vm-ctl` help/usage text consistent.
- Update `README.md` option tables/examples whenever flags/defaults/flows change.
- Update `llms.txt` for significant architecture or flow changes.
- If fixing an operational issue discovered in real usage, add a short note in `docs/LEARNINGS.md`.

When changing defaults or env vars:
- Keep `bin/vm-common.sh` defaults aligned with docs (`README.md`, `llms.txt`).
- Verify that generated systemd units and provision vars still match documentation examples.

## 6) Definition of Done for Typical Changes

Before finishing:
- Run `npm test`.
- If packaging-related changes were made, run `npm run pack:check`.
- Confirm docs were updated for any user-visible flag/default/flow change.
- Include exact file references in handoff notes for quick review.
