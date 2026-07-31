# Local-dev hostnames + static internal IPs (no port in URLs)

Goal: run demos and local tests against **cluster-forwarded** services as clean names on **port 80** (HTTP) or **default protocol ports** (Postgres/Redis), e.g.:

```text
http://weaviate.dev/
http://therobotplans.dev/
http://minio.dev/
# DB clients (default ports, no random 54330):
psql -h app-tsdb.dev -p 5432 ...
redis-cli -h app-valkey.dev -p 6379
```

This document is the **proposal + concrete map**. It pairs with `cluster-port-forward` (tunnels) and a small local edge (proxy +/or loopback aliases).

---

## Two patterns (pick one edge)

### Pattern A — **Recommended for HTTP demos**: Host-header reverse proxy

| Piece | Choice |
|-------|--------|
| Hosts | All names → `127.0.0.1` |
| Edge | Caddy/Traefik/nginx on **`:80`** |
| Routing | `Host: weaviate.dev` → `127.0.0.1:18081` (port-forward local) |
| DB/TCP | Still use forwarded high ports *or* Pattern B for DBs |

**Pros:** one IP, easy TLS later (`*.dev` local CA), no `ifconfig` aliases.  
**Cons:** non-HTTP (Postgres/Redis/gRPC) need either native ports in the URL or Pattern B.

### Pattern B — **Static internal IPs** on loopback (your `10.0.0.x` idea)

| Piece | Choice |
|-------|--------|
| Hosts | `weaviate.dev` → `10.0.0.41` |
| Edge | Each IP has its **own :80** (tiny proxy or app bind) *or* `kubectl port-forward --address 10.0.0.x` for TCP |
| Loopback | `sudo ifconfig lo0 alias 10.0.0.x netmask 255.255.255.0` (macOS) |

**Pros:** true `http://name/` with no shared proxy; DBs can be `host=name` `port=5432`.  
**Cons:** more setup; need alias lifecycle; more IPs to manage.

### Hybrid (recommended overall)

- **HTTP demos** → Pattern A (`*.dev` → `127.0.0.1`, Caddy `:80`)
- **Data plane (TSDB/Valkey)** → Pattern B aliases so apps use **standard 5432/6379** without remembering 54330/56379

---

## Reserved address plan (`10.0.0.0/24` local-only)

Use **loopback aliases only** (not LAN). Never route real traffic to these; document as *local-dev fabric*.

| Range | Purpose |
|-------|---------|
| `10.0.0.1` | Edge / default gateway name (`local.dev`) — optional |
| `10.0.0.10–19` | **Data**: Timescale / Valkey tiers |
| `10.0.0.20–29` | **Infra**: MinIO, Infisical, ClickHouse… |
| `10.0.0.40–49` | **AI**: Weaviate, Qdrant, TTS… |
| `10.0.0.60–89` | **Apps / demos**: portfolio products |
| `10.0.0.100+` | Scratch / one-off spikes |

Subnet mask for lo0 aliases on macOS: `255.255.255.0` is fine; traffic never leaves the host.

---

## Hostname zone

Use a **local-only** TLD that won’t fight production DNS:

| Zone | Use |
|------|-----|
| `*.dev.noizu.local` | Preferred (clearly local; won’t collide with public `*.noizu.com`) |
| `*.dev` | Shorter demos; ensure OS doesn’t force DNS-over-HTTPS for these names |
| `*.test` | Alternative reserved for testing |

Below tables use **short** `*.dev` labels; dual-write both in `/etc/hosts` if you want:

```text
10.0.0.41   weaviate.dev  weaviate.dev.noizu.local
```

---

## Full map: host → static IP → upstream (port-forward local)

Upstream ports match `share/port-forwards.catalog` (after `cluster-port-forward start …`).

### Data plane (TCP — Pattern B)

| Hostname | Static IP | Proto | Upstream (after PF) | Cluster target |
|----------|-----------|-------|---------------------|----------------|
| `app-tsdb.dev` | `10.0.0.10` | TCP **5432** | `127.0.0.1:54330` *or* PF bind to `10.0.0.10:5432` | `apps/svc/app-timescaledb:5432` |
| `app-valkey.dev` | `10.0.0.11` | TCP **6379** | `127.0.0.1:56379` | `apps/svc/app-valkey:6379` |
| `platform-tsdb.dev` | `10.0.0.12` | TCP **5432** | `127.0.0.1:54320` | `platform/svc/platform-timescaledb:5432` |
| `platform-valkey.dev` | `10.0.0.13` | TCP **6379** | `127.0.0.1:56380` | `platform/svc/platform-valkey:6379` |
| `infra-tsdb.dev` | `10.0.0.14` | TCP **5432** | `127.0.0.1:54310` | `infra/svc/infra-timescaledb:5432` |
| `infra-valkey.dev` | `10.0.0.15` | TCP **6379** | `127.0.0.1:56381` | `infra/svc/infra-valkey:6379` |

**Ideal PF bind for DBs** (no second hop):

```bash
# instead of 54330 on 127.0.0.1, bind standard port on the alias:
kubectl port-forward -n apps svc/app-timescaledb --address 10.0.0.10 5432:5432
# then: psql -h app-tsdb.dev -p 5432   (hosts → 10.0.0.10)
```

### Infra HTTP (port **80**)

| Hostname | Static IP | Upstream | Notes |
|----------|-----------|----------|-------|
| `minio.dev` | `10.0.0.20` | `127.0.0.1:9000` | S3 API (often path-style; Host may need careful proxy) |
| `minio-console.dev` | `10.0.0.21` | `127.0.0.1:9001` | Console UI |
| `infisical.dev` | `10.0.0.22` | `127.0.0.1:18080` | Cluster svc port 80 |

### AI HTTP / gRPC

| Hostname | Static IP | Upstream | Notes |
|----------|-----------|----------|-------|
| `weaviate.dev` | `10.0.0.41` | `127.0.0.1:18081` | HTTP **:80** via proxy or bind |
| `weaviate-grpc.dev` | `10.0.0.42` | `127.0.0.1:50051` | gRPC **:50051** (not 80) |
| `qdrant.dev` | `10.0.0.43` | `127.0.0.1:16333` | REST; optional proxy :80 → 16333 |
| `qdrant-grpc.dev` | `10.0.0.44` | `127.0.0.1:16334` | gRPC |

### App / demo HTTP (port **80**)

| Hostname | Static IP | Upstream | Cluster |
|----------|-----------|----------|---------|
| `therobotplans.dev` | `10.0.0.60` | API `14000` *or* UI `13000` | split: `api.therobotplans.dev` / `app.therobotplans.dev` |
| `api.therobotplans.dev` | `10.0.0.60` | `127.0.0.1:14000` | backend |
| `app.therobotplans.dev` | `10.0.0.61` | `127.0.0.1:13000` | frontend |
| `npl.dev` / `mcp.npl.dev` | `10.0.0.62` | `127.0.0.1:14040` | npl-mcp API |
| `app.npl.dev` | `10.0.0.63` | `127.0.0.1:13040` | npl UI |
| `therobotdrafts.dev` | `10.0.0.64` | `127.0.0.1:14041` | drafts API |
| `local.dev` | `10.0.0.1` | status page / Caddy root | optional hub |

Add portfolio demos the same way as they get port-forwards:

| Hostname | Suggested IP | Notes |
|----------|--------------|-------|
| `codefresh.dev` | `10.0.0.70` | when PF added |
| `therobotlearns.dev` | `10.0.0.71` | … |
| `derobot.is.local` | `10.0.0.72` | avoid clobbering real public DNS — prefer `derobot.dev` |

---

## `/etc/hosts` block (copy-paste)

```text
# --- Noizu local-dev fabric (loopback aliases; see local-dev-hosts.md) ---
# Edge
10.0.0.1    local.dev local.dev.noizu.local

# Data
10.0.0.10   app-tsdb.dev app-tsdb.dev.noizu.local
10.0.0.11   app-valkey.dev app-valkey.dev.noizu.local
10.0.0.12   platform-tsdb.dev platform-tsdb.dev.noizu.local
10.0.0.13   platform-valkey.dev platform-valkey.dev.noizu.local
10.0.0.14   infra-tsdb.dev infra-tsdb.dev.noizu.local
10.0.0.15   infra-valkey.dev infra-valkey.dev.noizu.local

# Infra HTTP
10.0.0.20   minio.dev minio.dev.noizu.local
10.0.0.21   minio-console.dev minio-console.dev.noizu.local
10.0.0.22   infisical.dev infisical.dev.noizu.local

# AI
10.0.0.41   weaviate.dev weaviate.dev.noizu.local
10.0.0.42   weaviate-grpc.dev weaviate-grpc.dev.noizu.local
10.0.0.43   qdrant.dev qdrant.dev.noizu.local
10.0.0.44   qdrant-grpc.dev qdrant-grpc.dev.noizu.local

# Apps / demos
10.0.0.60   api.therobotplans.dev api.therobotplans.dev.noizu.local
10.0.0.61   app.therobotplans.dev app.therobotplans.dev.noizu.local therobotplans.dev
10.0.0.62   mcp.npl.dev mcp.npl.dev.noizu.local
10.0.0.63   app.npl.dev app.npl.dev.noizu.local npl.dev
10.0.0.64   therobotdrafts.dev therobotdrafts.dev.noizu.local
```

**Pattern A alternative** (proxy-only — all on loopback):

```text
127.0.0.1  local.dev weaviate.dev qdrant.dev minio.dev minio-console.dev infisical.dev
127.0.0.1  api.therobotplans.dev app.therobotplans.dev therobotplans.dev
127.0.0.1  mcp.npl.dev app.npl.dev npl.dev therobotdrafts.dev
127.0.0.1  app-tsdb.dev app-valkey.dev platform-tsdb.dev platform-valkey.dev
127.0.0.1  infra-tsdb.dev infra-valkey.dev
```

---

## Loopback alias bootstrap (macOS)

```bash
# bring up static local IPs (ephemeral until reboot unless launchd)
for ip in 10.0.0.1 10.0.0.{10..15} 10.0.0.{20..22} 10.0.0.{41..44} 10.0.0.{60..64}; do
  sudo ifconfig lo0 alias "$ip" netmask 255.255.255.0
done
```

Tear down:

```bash
for ip in 10.0.0.1 10.0.0.{10..15} 10.0.0.{20..22} 10.0.0.{41..44} 10.0.0.{60..64}; do
  sudo ifconfig lo0 -alias "$ip" 2>/dev/null || true
done
```

---

## Caddy edge (Pattern A — HTTP demos on :80)

Install Caddy, then:

```caddy
# /usr/local/etc/Caddyfile  (example)
{
  auto_https off
}

weaviate.dev, weaviate.dev.noizu.local {
  reverse_proxy 127.0.0.1:18081
}

qdrant.dev, qdrant.dev.noizu.local {
  reverse_proxy 127.0.0.1:16333
}

infisical.dev, infisical.dev.noizu.local {
  reverse_proxy 127.0.0.1:18080
}

minio-console.dev, minio-console.dev.noizu.local {
  reverse_proxy 127.0.0.1:9001
}

# MinIO S3 API is picky about Host; path-style + proxy may need header tweaks:
minio.dev, minio.dev.noizu.local {
  reverse_proxy 127.0.0.1:9000
}

api.therobotplans.dev {
  reverse_proxy 127.0.0.1:14000
}

app.therobotplans.dev, therobotplans.dev {
  reverse_proxy 127.0.0.1:13000
}

mcp.npl.dev {
  reverse_proxy 127.0.0.1:14040
}

app.npl.dev, npl.dev {
  reverse_proxy 127.0.0.1:13040
}

therobotdrafts.dev {
  reverse_proxy 127.0.0.1:14041
}

local.dev {
  respond "Noizu local-dev edge OK" 200
}
```

Run: `caddy run --config …` (needs bind on :80 → root/setcap once).

**Flow:**

```text
Browser  →  http://weaviate.dev/     (hosts → 127.0.0.1)
         →  Caddy :80 (Host route)
         →  127.0.0.1:18081
         →  cluster-port-forward → platform-ai/weaviate
```

---

## Wiring `cluster-port-forward` (next enhancement)

Today PF always binds `127.0.0.1:local_port`. Optional catalog columns:

```text
# name ns svc remote local profiles [bind_ip] [bind_port]
app-tsdb  apps  svc/app-timescaledb  5432  54330  data  10.0.0.10  5432
weaviate  platform-ai svc/weaviate  80  18081  ai  10.0.0.41  80
```

Then:

```bash
kubectl port-forward -n … svc/… --address 10.0.0.41 80:80
```

Until that lands: use **Caddy** for HTTP :80, and for DBs either high ports on 127.0.0.1 or manual `--address 10.0.0.x 5432:5432`.

---

## Env examples (apps)

```bash
# After: cluster-port-forward watch data ai apps
#        + Caddy / aliases as above

export DATABASE_URL=ecto://USER:PASS@app-tsdb.dev:5432/therobotplans
export REDIS_URL=redis://app-valkey.dev:6379
export WEAVIATE_URL=http://weaviate.dev          # no :port
export WEAVIATE_GRPC_URL=weaviate-grpc.dev:50051 # gRPC keeps 50051
export INFISICAL_URL=http://infisical.dev
```

---

## What not to put on :80

| Service | Why |
|---------|-----|
| Postgres / Timescale | Not HTTP; use `:5432` on static IP |
| Valkey / Redis | Use `:6379` |
| Weaviate gRPC / Qdrant gRPC | Use 50051 / 6334 |
| MinIO S3 | Works on 80 via proxy but SDKs often want path-style + correct endpoint |

---

## Suggested rollout

1. **Now:** install hosts block (127.0.0.1 or 10.0.0.x) + run `cluster-port-forward watch data ai apps`.
2. **HTTP demos:** Caddyfile above → `http://therobotplans.dev`, `http://weaviate.dev`.
3. **DB convenience:** lo0 aliases + PF `--address 10.0.0.10 5432:5432` (or extend catalog).
4. **Later:** generate hosts + Caddy + aliases from one YAML next to `port-forwards.catalog` (`cluster-port-forward hosts install`).

---

## Summary

| Need | Proposal |
|------|----------|
| No port in browser URLs | Host-based reverse proxy on **:80** *or* per-service **10.0.0.x:80** |
| Stable names | `*.dev` + `*.dev.noizu.local` in `/etc/hosts` |
| Static IPs | `10.0.0.0/24` **loopback aliases** (not LAN) |
| Data DBs without 54330 | Bind PF to `10.0.0.1x:5432` / `:6379` |
| Source of truth | This map + `port-forwards.catalog` upstream ports |

No cluster DNS changes required — purely local host resolution + local edge + existing port-forwards.
