# AGENT-README

> Orientation for AI coding agents working in this repo. Human docs: README.md.

## Type

cli-tool+tui

## Purpose

`cluster-port-forward` — catalog-driven manager that keeps `kubectl port-forward` tunnels up (Timescale, Valkey, Weaviate, MinIO, Infisical, app backends) for local integration tests, with a supervising daemon, loopback web UI/API, and an ANSI TUI.

## Stack

Single bash script (`bin/cluster-port-forward`) + `share/port-forwards.catalog` (service catalog), `share/web/` (python-stdlib HTTP API + vanilla-JS dashboard), profile YAMLs under `~/.config/tunnel-watcher/`, launchd plist for the always-on daemon.

## Dev mode

```bash
make install    # → ~/.local/bin/cluster-port-forward
make test
make doctor     # check catalog services exist on the cluster

cluster-port-forward daemon start   # detached supervisor + web/API
cluster-port-forward up data ai     # whole profile via the daemon
```

## Ports / URLs

- Web UI/API: `127.0.0.1:4321` (daemon; `CPF_WEB_PORT` overrides) — loopback only.
- Tunnel local ports come from `share/port-forwards.catalog`: app-timescaledb 54330, platform 54320, infra 54310, valkey 56379–56381, minio 9000/9001, infisical 18080, weaviate 18081 (grpc 50051), qdrant 16333/16334, therobotplans 14000, npl-mcp 14040.

## Tests

```bash
make test    # bash assertion suite (see test/)
```

## Gotchas

- `KUBECONFIG` defaults to `~/.kube/noizu/config`; context via `KUBE_CONTEXT`.
- Flags go AFTER the subcommand (`cluster-port-forward tui --profile noizu`, not `--profile noizu tui` — the latter fails with a hint).
- `up`/`stop`/`status` are daemon clients — the daemon (not your shell) owns every tunnel, so closing the terminal is safe; without `daemon start` they fail loudly.
- Profile YAML is a strict subset: unknown syntax is a loud error with a line number. Multi-instance endpoints get local port `default_port + 2n + 4` — keep ≥20-port gaps between endpoints or colliding instance rows are dropped with a warning.
- Port 4321 is also Astro's dev-server default — `doctor` names the squatter if the port is taken.
