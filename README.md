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

```
cluster-port-forward (CLI)          cluster-port-forward daemon            cluster
  up / stop / status  ──HTTP──▶  ┌──────────────────────────┐   kubectl port-forward ─▶ svc/pod
  (thin client; same               │ supervises every tunnel  │   ssh -N -R (l2k)      ◀─ local
   table/json output)              │ per-key backoff, adopts  │
  browser ──HTTP──▶ 127.0.0.1:4321 │ dead rows, tears down on │
  (web UI: same rows, drill-down,  │ stop; launchd KeepAlive  │
   repoint, port edit, up/down)    └──────────────────────────┘
```

```bash
cluster-port-forward daemon start        # detached supervisor + web/API on 127.0.0.1:4321
cluster-port-forward daemon install      # launchd plist (KeepAlive, RunAtLoad) → starts at login
cluster-port-forward up                  # whole profile via the daemon, waits until online
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
- **Flag position**: flags go after the subcommand (`cluster-port-forward tui --profile noizu`, not `--profile noizu tui` — the latter fails with a hint). `tui --profile P` and `status --profile P` honor the flag the same way `up` does; `status --profile P` filters the profile-tunnel section to that profile's slugs, and the section always renders (naming the state dir when empty).

## Daemon & Web UI (port 4321)

`up`, `stop`, and `status` talk to a background daemon; the daemon — not your shell — owns every tunnel, so closing the terminal (or the agent's subshell) no longer kills your forwards.

```bash
cluster-port-forward daemon start      # fully detached; pidfile + log under the state dir
cluster-port-forward daemon status     # pid, web/API, profile, tunnel count
cluster-port-forward daemon logs       # tail -50 of the daemon log
cluster-port-forward daemon restart
cluster-port-forward daemon install    # ALWAYS-ON: launchd plist com.noizu.cluster-port-forward
cluster-port-forward daemon uninstall  # unload + remove plist
```

- **Ownership**: the daemon supervises ALL profile tunnels (per-key exponential backoff, caps at 60s), reloads shared state every tick, adopts/respawns dead rows at boot (launchd crash recovery restores your tunnels), and tears them down on `daemon stop` / TERM.
- **Web/API**: `http://127.0.0.1:4321` — loopback ONLY; python3 stdlib, no deps, no build. Dashboard = the `status` table with 2s refresh, per-row restart/stop/repoint/set-port, include+timeout bar, ns/svc filters. API: `GET /api/health`, `GET /api/tunnels`, `POST /api/up|/api/down|/api/restart|/api/repoint|/api/setport|/api/reload` (JSON; mutations are re-validated by the same profile/spec parser the CLI uses).
- **Port**: hard default 4321, override with `CPF_WEB_PORT`. `daemon start` refuses to start into an occupied port — if 4321 is taken, doctor names the squatter (Astro's dev-server default is the usual suspect).
- **CLI contract**: `up` keeps its exact output contract (table/`--json`, exit 0 iff all planned tunnels online) but renders from the daemon's shared state; daemon unreachable ⇒ loud refusal with the fix hint. `--dry-run` never touches the daemon. `watch`/`tui` and the legacy catalog subcommands are unchanged (foreground supervision remains available when you want it in-band).

