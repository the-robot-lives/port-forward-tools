# port-forward-utils — Architecture Summary

Pure-Bash package: one CLI `cluster-port-forward` supervises long-lived
`kubectl port-forward` tunnels for local tests against cluster data (TSDB,
Valkey, AI stores, MinIO, Infisical, app backends). No k8-lib / infra-config —
targets are `share/port-forwards.catalog`. Optional fabric: `lo0` aliases
(`10.0.0.x`), marked `/etc/hosts` (`*.dev`), Caddy `:80` Host routing.
Install: `make install` → `~/.local/bin` + `~/.local/share/noizu-port-forwards`.
Dual path: `Portfolio/Utilities/source/port-forward-utils` ↔
`utilities/k8/port-forward-utils`.

## Components

| Piece | Role |
|-------|------|
| `bin/cluster-port-forward` | start · watch · stop · status · list · doctor · hosts · aliases |
| `share/port-forwards.catalog` | name/ns/svc/remote/local/profiles/[bind_ip]/bind_port] |
| `share/hosts.local-dev` + Caddyfile + sudoers | Pattern A/B local-dev edge |
| State dir (`CPF_STATE_DIR`) | pid/meta/logs/selection; `external` if port already open |
| `Makefile` | install · `bash -n` test · doctor |

## Runtime

- Always PF `127.0.0.1:local_port`; if `CPF_BIND=1` and alias up, also
  `bind_ip:bind_port` (std 5432/6379/80 for apps).
- `watch` polls every `CPF_POLL_SEC` (3s) and restarts dead tunnels; Ctrl-C stops.
- Profiles: `data` · `platform` · `infra` · `ai` · `apps` · `minio` · `all`.
- Credentials out of scope; not a substitute for liquibase-shell short-lived PF.

## Key Decisions

- Single self-contained script (no shared lib)
- Catalog-driven topology (operator ports/aliases, not deploy YAML)
- Dual bind: high ports for Caddy/tools; alias std ports for DB clients
- Never steal open local ports (`external`)
- macOS-first aliases/sudoers; Caddy optional for HTTP demos

## Tech Stack

Bash · kubectl port-forward · nc|/dev/tcp · ifconfig lo0 · tee /etc/hosts ·
optional Caddy · make install
