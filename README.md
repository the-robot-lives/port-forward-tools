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
