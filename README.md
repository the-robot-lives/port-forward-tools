# port-forward-utils

**Repo:** https://github.com/the-robot-lives/port-forward-tools

Keep `kubectl port-forward` tunnels up for local tests against cluster data (Timescale, Valkey, Weaviate, MinIO, Infisical, app backends).

## What

`cluster-port-forward` — a catalog-driven port-forward manager with a watch supervisor that restarts forwards on disconnect.

## Why

Local integration tests need prod-like data services that aren't exposed publicly. Ad-hoc `kubectl port-forward` invocations die silently and don't compose; this tool keeps a declared set of tunnels (with stable local ports) alive and observable.

## Getting Started

Prerequisites: `kubectl`, `nc` (or bash `/dev/tcp`), `KUBECONFIG` (defaults to `~/.kube/noizu/config`).

```bash
make install    # → ~/.local/bin/cluster-port-forward  (make test / make doctor also available)
```

```bash
cluster-port-forward doctor                 # check catalog services exist on the cluster
cluster-port-forward list                   # list catalog (name, ns, ports, profiles)
cluster-port-forward start data [ai ...]    # one-shot start, no supervisor
cluster-port-forward watch data ai minio    # supervise: re-link on disconnect [Ctrl-C stops]
cluster-port-forward status
cluster-port-forward stop [weaviate]
```

Profiles: `data` (app/platform/infra TSDB + Valkey), `ai` (weaviate, weaviate-grpc, qdrant), `infra` (minio, minio-console, infisical, infra tsdb/valkey), `platform`, `apps` (tsdb/valkey + therobotplans / npl-mcp / drafts backends), `minio`, `all`.

## How It Works

- **Catalog**: `share/port-forwards.catalog` (or `$CPF_CATALOG`) declares services — namespace, remote ports, local ports, profile membership. Edit it to add targets.
- **Stable local ports** (defaults): app-timescaledb 54330, platform 54320, infra 54310; valkey 56379-56381; minio 9000/9001; infisical 18080; weaviate 18081 (grpc 50051); qdrant 16333/16334; therobotplans 14000; npl-mcp 14040.
- **Supervision**: `watch` polls each tunnel (`CPF_POLL_SEC`, default 3s) and restarts forwards that drop; state lives under `$XDG_RUNTIME_DIR/noizu-port-forwards` (or `/tmp`).
- **Env**: `KUBECONFIG`, `KUBE_CONTEXT`, `CPF_STATE_DIR`, `CPF_POLL_SEC`.

Docs: `docs/` (PROJ-ARCH, PROJ-LAYOUT, PROJ-SCHEMA).

## Tunnel Profiles (up / tui)

Profile-driven headless + interactive tunnel management on top of the catalog surface.

```bash
cluster-port-forward up                              # whole profile, waits until online (exit 0/1)
cluster-port-forward up --profile noizu --json       # machine-readable plan result
cluster-port-forward up --include valkey-latest valkey-oldest:7100 app-tsdb/apps  # spec grammar
cluster-port-forward tui                             # ANSI table: j/k move, enter drills ns→svc→pods,
                                                     # p persists a port into the profile, s/r/a/K/q/Q
```

- **Profiles**: `~/.config/tunnel-watcher/<name>.yaml` (resolved via `--profile`, else `$TUNNEL_WATCHER_PROFILE`); strict subset of YAML — unknown syntax is a loud error with a line number. `make install` seeds `noizu.yaml` (valkey on 6308 with multi-instance, platform-valkey 6360, commented local→cluster reverse example) only if absent; template at `share/profiles/noizu.yaml.example`.
- **Include specs** (repeatable, comma-separated): `slug` (default + all instances), `slug-oldest|-latest|-num-N|-default`, `slug[:PORT]` (override), `name/namespace[:PORT]` (raw catalog bypass). Missing port and no `default_port` ⇒ loud refusal, non-zero exit.
- **Multi-instance**: endpoints with `instances: true` enumerate pods oldest→newest via the svc selector; instance n gets local port `default_port + 2n + 4` (6308 → 6314, 6316, …). Plan-time overlap: defaults win, colliding instance rows are dropped with a 🔥 warning (keep ≥20-port gaps between endpoints).
- **Reverse (local→cluster) tunnels**: endpoints with `direction: l2k` run `ssh -N -R *:<remote_port>:127.0.0.1:<local_port>` (autossh when available) against `ssh_host`; health is an `nc` probe of the node IP.
- **Env**: `TUNNEL_WATCHER_PROFILE`, `TUNNEL_WATCHER_DIR` (config dir, default `~/.config/tunnel-watcher`); `up` flags: `--timeout 30s|5m|1h`, `--json`, `--dry-run`, `--watch`, `--tui`.

