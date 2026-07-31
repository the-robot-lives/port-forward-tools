# cluster-port-forward

Keep `kubectl port-forward` tunnels **up** for local tests against cluster
(prod-like) data: Timescale, Valkey, Weaviate, MinIO, Infisical, app backends.

On disconnect the **watch** supervisor restarts each forward.

## Install

```bash
cd utilities/k8/port-forward-utils
make install          # → ~/.local/bin/cluster-port-forward
```

Requires: `kubectl`, `nc` (or bash `/dev/tcp`), `KUBECONFIG` (defaults to
`~/.kube/noizu/config`).

## Usage

```bash
# Check catalog services exist on the cluster
cluster-port-forward doctor

# List catalog (name, ns, ports, profiles)
cluster-port-forward list

# One-shot start (no supervisor)
cluster-port-forward start data          # app/platform/infra TSDB + Valkey
cluster-port-forward start data ai       # + weaviate/qdrant
cluster-port-forward start all

# Supervise (recommended): re-link on disconnect  [Ctrl-C stops]
cluster-port-forward watch data ai minio

# Status / stop
cluster-port-forward status
cluster-port-forward stop
cluster-port-forward stop weaviate
```

### Profiles

| Profile    | Services |
|------------|----------|
| `data`     | app/platform/infra timescaledb + valkey |
| `ai`       | weaviate, weaviate-grpc, qdrant |
| `infra`    | minio, minio-console, infisical, infra tsdb/valkey |
| `platform` | platform tsdb/valkey |
| `apps`     | app tsdb/valkey + therobotplans / npl-mcp / drafts backends |
| `minio`    | minio API + console |
| `all`      | everything in the catalog |

### Local ports (defaults)

| Service | Local |
|---------|-------|
| app-timescaledb | **54330** |
| platform-timescaledb | **54320** |
| infra-timescaledb | **54310** |
| app-valkey | **56379** |
| platform-valkey | **56380** |
| infra-valkey | **56381** |
| minio | **9000** / console **9001** |
| infisical | **18080** |
| weaviate | **18081** |
| weaviate-grpc | **50051** |
| qdrant | **16333** / grpc **16334** |
| therobotplans API | **14000** |
| npl-mcp | **14040** |

Edit `share/port-forwards.catalog` (or `$CPF_CATALOG`) to add targets.

## Env

| Variable | Default |
|----------|---------|
| `KUBECONFIG` | `~/.kube/noizu/config` |
| `KUBE_CONTEXT` | (kubectl default) |
| `CPF_STATE_DIR` | `$XDG_RUNTIME_DIR/noizu-port-forwards` or `/tmp/...` |
| `CPF_POLL_SEC` | `3` |
| `CPF_CATALOG` | installed share path |

## Example: local tests against cluster data

```bash
# Terminal 1 — keep tunnels alive
cluster-port-forward watch data ai

# Terminal 2 — point app at forwarded endpoints
export DATABASE_URL=ecto://USER:PASS@127.0.0.1:54330/therobotplans
export REDIS_URL=redis://127.0.0.1:56379
export WEAVIATE_URL=http://127.0.0.1:18081
mix test
```

Credentials still come from Infisical / k8s secrets / `dc` — this tool only
forwards ports.

## Clean hostnames (no port in URLs)

See **[share/local-dev-hosts.md](share/local-dev-hosts.md)** for the proposal:

- Static **`10.0.0.0/24`** loopback aliases + `/etc/hosts` (`*.dev`)
- Or **Caddy on :80** Host-routing to forwarded ports
- Ready-to-paste: `share/hosts.local-dev`, `share/Caddyfile.local-dev`

```bash
# tunnels
cluster-port-forward watch data ai apps

# optional HTTP edge (no :port in browser)
sudo caddy run --config share/Caddyfile.local-dev
# → http://weaviate.dev  http://therobotplans.dev  http://infisical.dev
```

## Notes

- If a local port is already open, the tool **does not steal it** (marks
  `external`). Free the port or change the catalog local port.
- Logs: `$CPF_STATE_DIR/<name>.kubectl.log` and `supervisor.log`.
- Not a replacement for `liquibase-shell` (which still does its own short-lived
  PF + secret fetch for migrations).

