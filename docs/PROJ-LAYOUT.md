# Project Layout — port-forward-utils

<!-- 〚📁:4191ab08-ebeb-5020-8e97-c5e2a7bf0550〛 PROJ-LAYOUT :: Repo layout map — bin/share/test/docs tree, install mapping, CLI surface -->
Terminal utility: supervised `kubectl port-forward` tunnels for local tests
against cluster data (TSDB, Valkey, Weaviate, MinIO, Infisical, app backends).
Profile-driven tunnel management (headless `up`, `tui`, always-on `daemon` +
loopback web dashboard) on top of the legacy catalog surface. Optional loopback
aliases (`10.0.0.x`) + `/etc/hosts` + Caddy edge for clean `*.dev` hostnames.
Installs to `~/.local/bin` + `~/.local/share/noizu-port-forwards` via `make
install` (or monorepo `make install-utilities`). Dual-path:
`Portfolio/Utilities/source/port-forward-utils` ↔ `utilities/k8/port-forward-utils`.

Plain tree: [PROJ-LAYOUT.summary.md](PROJ-LAYOUT.summary.md).

```
port-forward-utils/
├── bin/
│   └── cluster-port-forward        # CLI (~2.3k lines bash) → ~/.local/bin (install -m 755)
├── share/                          # Catalog + local-dev fabric → SHARE_DIR
│   ├── port-forwards.catalog       #   name ns svc remote local profiles [bind]
│   ├── hosts.local-dev             #   /etc/hosts block (*.dev / 10.0.0.x)
│   ├── Caddyfile.local-dev         #   Pattern A: :80 Host → 127.0.0.1:highport
│   ├── local-dev-hosts.md          #   Design notes (Pattern A/B, IP ranges)
│   ├── sudoers.d-noizu-local-dev   #   NOPASSWD ifconfig/tee digests (macOS)
│   ├── profiles/                   #   Tunnel-profile templates
│   │   └── noizu.yaml.example      #     starter profile (k2l + commented l2k)
│   └── web/                        #   Daemon web UI + API (installed to SHARE_DIR/web)
│       ├── index.html              #     vanilla-JS dashboard (no build, no deps)
│       └── server.py               #     stdlib-only loopback API server (127.0.0.1:4321)
├── test/                           # Plain-bash assertion suite (sandboxed, fake kubectl/ssh)
│   ├── run-tests.sh                #   157 assertions; `make test`
│   └── fixtures/                   #   fake kubectl/ssh + profile/catalog fixtures
├── docs/
│   ├── PROJ-ARCH.md(+.summary)     #   Architecture + runtime model
│   ├── PROJ-LAYOUT.md(+.summary)   #   This file + tree-only companion
│   ├── PROJ-SCHEMA.md(+.summary)   #   Config/state/API artifact schema (no DB)
│   ├── THREAT-MODEL.md(+.summary)  #   Trust boundaries + STRIDE register
│   └── (no PROJ-HOWTO / FAQ yet)
├── Makefile                        # install | test (bash -n + suite) | doctor
├── README.md                       # Start here — usage, profiles, ports, env
├── AGENT.md / AGENTS.md            # Agent-session pointers (kept aligned)
├── CLAUDE.md                       # Agent instructions (worktree + PR policy)
└── merge-notes.md                  # Branch-sweep/merge history notes (sep-1)
```

## Install mapping (`make install`)

| Source | Install path | Method |
|--------|--------------|--------|
| `bin/cluster-port-forward` | `~/.local/bin/cluster-port-forward` | copy (`install -m 755`) |
| `share/*` (catalog, hosts, Caddyfile, md, sudoers) | `~/.local/share/noizu-port-forwards/` | copy (`install -m 644`) |
| `share/profiles/noizu.yaml.example` | `~/.local/share/noizu-port-forwards/profiles/` + seeds `~/.config/tunnel-watcher/noizu.yaml` only if absent | copy (`install -m 644`) |
| `share/web/index.html` + `share/web/server.py` | `~/.local/share/noizu-port-forwards/web/` | copy (`644` / `755`) |

Overrides: `INSTALL_DIR=…`, `SHARE_DIR=…`. Runtime catalog resolution order:
`$CPF_CATALOG` → script-relative `../share/` → `$XDG_DATA_HOME/...` →
`~/.local/share/noizu-port-forwards/`.

## CLI surface (`cluster-port-forward`)

| Command | Role |
|---------|------|
| `start [profile\|name …]` | One-shot port-forwards (default profile: `data`) |
| `watch [profile\|name …]` | Start + supervise; restart on disconnect (Ctrl-C stops) |
| `stop [name\|all]` | Kill supervised / selected PFs |
| `status` / `list` | Live state vs catalog; catalog dump (`status --profile P` filters) |
| `doctor` | Cluster reachability, catalog Service existence, daemon/web/l2k checks |
| `hosts print\|install\|uninstall` | Manage marked block in `/etc/hosts` |
| `aliases up\|down\|status` | macOS `lo0` aliases for catalog `bind_ip`s |
| `up [--profile P] [spec …]` | Whole profile via daemon, waits until online (`--json`, `--dry-run`, `--watch`, `--tui`, `--timeout`) |
| `tui` | ANSI table: drill ns→svc→pods, persist ports, restart/arm/teardown |
| `daemon start\|stop\|restart\|status\|logs\|install\|uninstall` | Always-on supervisor + web/API on `127.0.0.1:4321` (`daemon install` = launchd plist) |
| `profile-parse` | Debug: parse a profile, dump normalized endpoints |

Profiles in catalog: `data`, `platform`, `infra`, `ai`, `apps`, `minio`, `all`.
Tunnel profiles: `~/.config/tunnel-watcher/<name>.yaml` (strict YAML subset).

## Notes

- **No `lib/` / k8-lib** — single self-contained bash script + share files
  (web dashboard is stdlib-only python).
- **Catalog columns**: `name namespace service remote_port local_port profiles [bind_ip] [bind_port]`.
  Loopback high ports always; optional secondary PF to `bind_ip:bind_port` when
  `CPF_BIND=1` (default) and the alias is up.
- **State**: `$CPF_STATE_DIR` (default `$XDG_RUNTIME_DIR/noizu-port-forwards` or
  `/tmp/...`) — pid/meta/logs per name, `tunnels.tsv` + `daemon.pid`/`daemon.log`
  for the daemon, `selection.txt`.
- **Does not steal ports** — open local port marked `external`.
- **Not** a substitute for `liquibase-shell` short-lived PF + secret fetch.
- **Prereqs**: `kubectl`, `nc` (or bash `/dev/tcp`); optional Caddy for Pattern A;
  sudoers template for passwordless hosts/aliases on macOS.
- **Makefile**: `test` = `bash -n` + `test/run-tests.sh`; `doctor` shells to
  installed/local binary.

## Key files requiring setup

| File / artifact | Action |
|-----------------|--------|
| `KUBECONFIG` | Default `~/.kube/noizu/config`; optional `KUBE_CONTEXT` |
| `share/port-forwards.catalog` (or `$CPF_CATALOG`) | Edit to add targets / change local ports |
| `~/.config/tunnel-watcher/<name>.yaml` | Tunnel profile (seeded from `share/profiles/noizu.yaml.example` on install) |
| `share/sudoers.d-noizu-local-dev` | Optional: copy to `/etc/sudoers.d/noizu-local-dev` (set user, `visudo -c`) |
| `cluster-port-forward aliases up` + `hosts install` | Pattern B clean hostnames / std DB ports |
| Caddy + `share/Caddyfile.local-dev` | Pattern A HTTP demos on `:80` |
