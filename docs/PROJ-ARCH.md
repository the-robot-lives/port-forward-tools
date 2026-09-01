# port-forward-utils — Architecture

## Overview

**port-forward-utils** is a pure-Bash package with one CLI,
`cluster-port-forward`, that keeps long-lived `kubectl port-forward` tunnels
alive for local tests against cluster (prod-like) data: Timescale, Valkey,
Weaviate, Qdrant, MinIO, Infisical, and app backends.

There is **no in-repo library** and **no k8-lib dependency**. Targets live in a
whitespace catalog (`share/port-forwards.catalog`); runtime state is pid/meta/log
files under `$CPF_STATE_DIR`. Optional local-dev fabric: macOS `lo0` aliases
(`10.0.0.x`), marked `/etc/hosts` blocks (`*.dev`), and a Caddyfile for
Host-based `:80` routing.

Package location (dual path in monorepo):
`Portfolio/Utilities/source/port-forward-utils` ↔ `utilities/k8/port-forward-utils`.

Install: `make install` → `~/.local/bin/cluster-port-forward` +
`~/.local/share/noizu-port-forwards/*` (or monorepo `make install-utilities`).

## System Diagram

```mermaid
graph TB
    CLI[cluster-port-forward]
    CAT[port-forwards.catalog<br/>name ns svc remote local profiles bind]
    ST[(CPF_STATE_DIR<br/>pid · meta · kubectl.log · selection)]
    K8S[Kubernetes API<br/>kubectl port-forward]
    LO[127.0.0.1:high_port]
    AL[10.0.0.x:std_port<br/>lo0 aliases]
    HOSTS[/etc/hosts<br/>BEGIN/END noizu-local-dev]
    CAD[Caddy :80<br/>Caddyfile.local-dev]
    APP[Local apps / tests / psql / redis-cli]

    CLI -->|load / resolve profiles| CAT
    CLI -->|start / ensure / stop| ST
    CLI -->|kubectl --address| K8S
    K8S --> LO
    K8S -.->|CPF_BIND=1 + alias up| AL
    CLI -->|aliases up/down| AL
    CLI -->|hosts install/uninstall| HOSTS
    CAD -->|reverse_proxy| LO
    APP --> LO
    APP -.->|Pattern B hostnames| AL
    APP -.->|Pattern A HTTP| CAD
```

## Core Components

| Component | Role |
|-----------|------|
| `bin/cluster-port-forward` (~579 loc) | Sole executable: catalog load, selection, PF lifecycle, supervisor loop, hosts/aliases helpers |
| `share/port-forwards.catalog` | Declarative targets (profiles + optional `bind_ip`/`bind_port`) |
| `share/hosts.local-dev` | Host→`10.0.0.x` block for `hosts install` |
| `share/Caddyfile.local-dev` | Pattern A: Host header → `127.0.0.1:local_port` |
| `share/local-dev-hosts.md` | Design notes (Pattern A/B, IP ranges, hybrid) |
| `share/sudoers.d-noizu-local-dev` | macOS NOPASSWD digests for `ifconfig lo0` + `tee /etc/hosts` |
| `Makefile` | `install` (copy bin + share), `test` (`bash -n`), `doctor` |

## CLI surface

| Command | Behavior |
|---------|----------|
| `start [profile\|name …]` | One-shot PF for selection (default profile: `data`); writes `selection.txt` |
| `watch` / `supervise` / `daemon` | Start + poll `ensure_one` every `CPF_POLL_SEC` (default 3); Ctrl-C / EXIT stops selection |
| `stop [name\|all]` | Kill selected (or last selection / all catalog names) |
| `status` / `st` | Per-name PID, loopback open?, bind open?, state (`up` / `port-up` / `down` / `off`) |
| `list` / `ls` | Dump catalog columns including bind |
| `doctor` / `check` | Cluster reachability + each catalog `ns/svc` existence |
| `hosts print\|blurb\|install\|uninstall` | Manage marked Noizu block in `/etc/hosts` |
| `aliases up\|down\|status` | macOS `lo0` aliases for distinct catalog `bind_ip`s (+ always `10.0.0.1`) |

Profiles resolved from catalog membership: `data`, `platform`, `infra`, `ai`,
`apps`, `minio`, `all` (or individual service names). Selection is de-duplicated.

## Catalog model

Whitespace-separated lines (comments/`#` skipped):

```text
name  namespace  service  remote_port  local_port  profiles  [bind_ip]  [bind_port]
```

| Field | Meaning |
|-------|---------|
| `local_port` | Always forwarded on **`127.0.0.1`** (Caddy / tools / high ports) |
| `profiles` | Comma list for group start (`data,apps,all`) |
| `bind_ip` / `bind_port` | Optional second PF with `--address bind_ip` (Pattern B std ports) |

Resolution order for catalog (and hosts file): `$CPF_CATALOG` / `$CPF_HOSTS_FILE`
if set and exists → script-relative `../share/` →
`${XDG_DATA_HOME:-~/.local/share}/noizu-port-forwards/` →
`~/.local/share/noizu-port-forwards/`.

Default catalog maps three TSDB/Valkey tiers (apps/platform/infra), MinIO +
console + Infisical, Weaviate/gRPC + Qdrant/gRPC, and portfolio backends
(therobotplans API/UI, npl-mcp/UI, therobotdrafts).

## Runtime flow

### Start / ensure (per service)

1. `load_catalog` → parallel bash arrays (`NAME`, `NS`, `SVC`, …)
2. `resolve_selection` tokens → unique service names
3. **Loopback PF**: `kubectl port-forward -n NS SVC --address 127.0.0.1 LP:RP`
4. If `CPF_BIND=1` (default) and catalog has bind fields and `ip_usable(bind_ip)`:
   second PF `--address bind_ip BP:RP` (pid file `*.bind.pid`)
5. If local port already open and not owned by tracked pid → mark pid
   **`external`** (do not reclaim / kill)
6. Wait up to ~9s (`30 × 0.3s`) for port open via `nc` or bash `/dev/tcp`
7. Write `name.meta` (ns/svc/ports/bind) + kubectl logs under state dir

### Watch supervisor

Foreground loop: for each selected name, `ensure_one` restarts dead or
non-listening PFs; sleep `CPF_POLL_SEC`. Trap INT/TERM/EXIT runs `stop_one` for
the selection only.

### State directory

Default: `${XDG_RUNTIME_DIR:-/tmp}/noizu-port-forwards` (`CPF_STATE_DIR`).

| Artifact | Purpose |
|----------|---------|
| `<name>.pid` / `<name>.bind.pid` | kubectl PF PIDs (or `external`) |
| `<name>.meta` | Last start metadata |
| `<name>.kubectl.log` / `<name>-bind.kubectl.log` | PF process stdout/err |
| `selection.txt` | Last start/watch selection (used by bare `stop`) |
| `supervisor.log` | Timestamped start/reconnect lines (`CPF_LOG` override) |

## Local-dev fabric (optional)

Two complementary patterns (documented in `share/local-dev-hosts.md`):

| Pattern | Mechanism | Best for |
|---------|-----------|----------|
| **A** | All names → `127.0.0.1`; Caddy/nginx on `:80` Host-routes to high `local_port` | HTTP demos without remembering ports |
| **B** | `lo0` aliases `10.0.0.x` + hosts map; PF binds std ports (5432/6379/80) on alias IPs | DB/TCP clients wanting default ports |

**Hybrid (recommended):** A for HTTP UIs; B for data plane.

Reserved local-only ranges (loopback aliases, not LAN): `.1` edge; `.10–19`
data; `.20–29` infra; `.40–49` AI; `.60–89` apps. Hosts dual-label
`*.dev` and `*.dev.noizu.local`.

`aliases` uses `sudo /sbin/ifconfig lo0 alias| -alias` (macOS-centric).
`hosts install` rewrites `/etc/hosts` via `sudo /usr/bin/tee` with
`# BEGIN/END noizu-local-dev` markers. Optional sudoers template pins binary
sha256 digests for passwordless use (user hard-coded in template — edit before
install).

## Configuration / environment

| Variable | Default | Role |
|----------|---------|------|
| `KUBECONFIG` | `~/.kube/noizu/config` | kubectl kubeconfig |
| `KUBE_CONTEXT` | (unset) | optional `--context` |
| `CPF_STATE_DIR` | `$XDG_RUNTIME_DIR/noizu-port-forwards` or `/tmp/...` | runtime state |
| `CPF_CATALOG` | resolved share path | catalog override |
| `CPF_HOSTS_FILE` | resolved `hosts.local-dev` | hosts block source |
| `CPF_BIND` | `1` | enable secondary bind_ip PFs |
| `CPF_POLL_SEC` | `3` | watch poll interval |
| `CPF_LOG` | `$STATE_DIR/supervisor.log` | supervisor log path |

No `infra-config.yaml` / k8-lib: topology is the catalog file only.

## Key Decisions

| Decision | Rationale |
|----------|-----------|
| Single self-contained bash script | Zero install deps beyond kubectl + shell; no shared lib version skew |
| Catalog file, not infra-config | PF targets are operator-local (ports/aliases) more than deploy topology |
| Dual bind (loopback + optional alias) | Caddy/tools keep high ports; apps can use host=`*.dev` port=5432 |
| Never steal open ports (`external`) | Avoid killing foreign processes; operator frees or changes catalog local port |
| Supervisor is foreground watch only | Simple Ctrl-C lifecycle; no systemd/launchd daemon in-package |
| Credentials out of scope | Tool only tunnels; secrets from Infisical / k8s / `dc` as usual |
| Not a liquibase-shell replacement | Migrations keep short-lived PF + secret fetch; this is long-lived multi-service |
| macOS-first aliases/sudoers | Primary laptop OS for Noizu local-dev; Linux aliases need different tooling |

## Tech Stack

| Layer | Choice |
|-------|--------|
| Language | Bash (`set -euo pipefail`) |
| Cluster | `kubectl port-forward` |
| Port probe | `nc -z` (fallback `/dev/tcp`) |
| Alias / hosts | `ifconfig lo0`, `tee /etc/hosts` (sudo) |
| Optional HTTP edge | Caddy + `share/Caddyfile.local-dev` |
| Install | `make` + `install -m 755/644` |
| Tests | `bash -n` only |

## External runtime prerequisites

| Tool / condition | Required for |
|------------------|--------------|
| `kubectl` + reachable cluster | All PF / doctor |
| `nc` or bash `/dev/tcp` | Liveness / ready checks |
| macOS `ifconfig lo0` + sudo | `aliases up` (Pattern B) |
| sudo write `/etc/hosts` | `hosts install` |
| Caddy (optional) | Pattern A HTTP demos |
| Catalog Services present in cluster | Successful tunnels (doctor surfaces gaps) |

## Ecosystem fit

Sibling of `cluster-utils`, `database-utils`, `docker-utils`, `secret-utils` under
monorepo utilities. Complements short-lived PFs in `liquibase-shell` /
`provision-db` by providing **persistent multi-service** tunnels for app tests
and demos. Does not integrate Infisical or Helm; sits beside them in the local
dev loop.

## Related docs

- Layout tree: [PROJ-LAYOUT.md](PROJ-LAYOUT.md)
- Config/state artifact schema: [PROJ-SCHEMA.md](PROJ-SCHEMA.md)
- Operator usage: [../README.md](../README.md)
- Local hostname design: [../share/local-dev-hosts.md](../share/local-dev-hosts.md)
