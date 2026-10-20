# CHANGELOG

## 2026-10-20

- bin/cluster-port-forward: tunnel-profile engine — YAML profile parsing (`pf_parse`, strict fixed subset, line-numbered errors), profile resolution (`--profile` → `$TUNNEL_WATCHER_PROFILE` → cwd), include-spec grammar (`slug`, `-oldest/-latest/-num-N/-default`, `slug[:PORT]`, raw `name/namespace[:PORT]`), multi-instance pod enumeration with `base + 2n + 4` local ports and plan-time overlap dropping, headless `up` (`--timeout`, `--json`, `--dry-run`, `--watch`, `--tui`), reverse l2k tunnels (`ssh -N -R`, autossh-or-ssh, node-IP `nc` health), TUI (`tui` subcommand: drill ns→svc→pods, persist port into profile yaml, restart/arm/teardown), doctor additions (ssh reachability, GatewayPorts, l2k probes, port-gap warnings), status appendix + `stop all` wiring, `profile-parse` debug subcommand (#tunnel-profiles).
- share/profiles/noizu.yaml.example: seeded profile template (valkey 6308 instances:true latest, platform-valkey 6360, commented timescale-local l2k 6987→6001 with ≥20-gap guidance).
- Makefile: install `share/profiles/` + example; seed `~/.config/tunnel-watcher/noizu.yaml` only if absent; `test` target runs `test/run-tests.sh`.
- test/: 101-assertion suite (`run-tests.sh` + fixtures) — sandboxed HOME/XDG_RUNTIME_DIR, fake kubectl/ssh (never touches a cluster), parser/resolution/spec-math/instance/collision/l2k/doctor/regression coverage.
- README.md: Tunnel Profiles section (up/tui/profiles/spec grammar/env).
