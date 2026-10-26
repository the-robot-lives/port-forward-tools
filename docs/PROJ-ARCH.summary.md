# port-forward-utils — Architecture Summary

Pure-Bash package (~2.3k-line CLI + stdlib python web server): one binary,
`cluster-port-forward`, keeps long-lived `kubectl port-forward` tunnels alive
for local tests against cluster data (TSDB, Valkey, AI stores, MinIO,
Infisical, app backends). No k8-lib / infra-config. Install: `make install` →
`~/.local/bin` + `~/.local/share/noizu-port-forwards`. Dual path:
`Portfolio/Utilities/source/port-forward-utils` ↔ `utilities/k8/port-forward-utils`.

## Two management layers

- **Catalog surface** (legacy): `share/port-forwards.catalog` targets,
  foreground `start`/`watch` supervisor, optional `bind_ip` dual-bind,
  hosts/aliases/Caddy local-dev fabric.
- **Tunnel-profile engine**: strict-subset YAML profiles
  (`~/.config/tunnel-watcher/`), multi-instance pods (`base + 2n + 4`), l2k
  reverse tunnels (`ssh -N -R`), headless `up` (`--json/--dry-run/--watch/--tui`),
  interactive `tui`, always-on `daemon` (launchd KeepAlive) owning all tunnels
  in `tunnels.tsv` + loopback web UI/API on `127.0.0.1:4321`.

## Components

| Piece | Role |
|-------|------|
| `bin/cluster-port-forward` | start · watch · stop · status · list · doctor · hosts · aliases · up · tui · daemon · profile-parse (+ hidden `__api-*`) |
| `share/port-forwards.catalog` | legacy targets: name/ns/svc/remote/local/profiles/[bind_ip bind_port] |
| `share/profiles/noizu.yaml.example` | starter tunnel profile (k2l + commented l2k) |
| `share/web/server.py` + `index.html` | daemon-spawned loopback API + vanilla-JS dashboard |
| `test/run-tests.sh` | 157 assertions on fake kubectl/ssh |
| State dir (`CPF_STATE_DIR`) | pid/meta/logs/selection + `tunnels.tsv` + `daemon.pid`/`daemon.log` |

## Runtime

- Daemon owns every profile tunnel: per-key exponential backoff (cap 60s),
  state reload each tick, adopts dead rows at boot, tears down on stop/TERM.
- `up`/`stop`/`status` are daemon clients with the same table/`--json` contract.
- Web API mutations are regex-validated and re-parsed by the CLI's
  profile/spec parser (`__api-*` execs, `CPF_API_INTERNAL=1`).
- Legacy `watch` polls every `CPF_POLL_SEC` (3s); open-but-unowned ports are
  marked `external` and never killed.
- Credentials out of scope; not a substitute for liquibase-shell short-lived PF.

## Key Decisions

- Single self-contained script (+ stdlib python web) — no deps beyond kubectl/ssh/python3
- Catalog-driven topology; strict-YAML profiles with loud line-numbered errors
- Daemon owns tunnels (shell exit/reboot-safe); loopback-only web API with CLI re-validation
- Never steal open ports; l2k reverse tunnels opt-in with ≥20-port gaps + doctor GatewayPorts check
- macOS-first aliases/sudoers; Caddy optional for HTTP demos

## Tech Stack

Bash · kubectl port-forward · ssh -N -R (autossh) · nc|/dev/tcp · ifconfig lo0 ·
tee /etc/hosts · python3 stdlib web · launchd · optional Caddy · make install
