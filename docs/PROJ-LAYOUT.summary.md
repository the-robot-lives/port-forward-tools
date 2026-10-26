# Project Layout — Summary

Supervised k8s port-forwards + profile-driven tunnel daemon + local-dev
hosts/aliases fabric.
Full annotated tree: [PROJ-LAYOUT.md](PROJ-LAYOUT.md).

```
port-forward-utils/
├── bin/
│   └── cluster-port-forward        # start · watch · stop · status · list · doctor · hosts · aliases · up · tui · daemon · profile-parse
├── share/
│   ├── port-forwards.catalog       # PF targets + profiles + optional bind_ip
│   ├── hosts.local-dev             # *.dev → 10.0.0.x block
│   ├── Caddyfile.local-dev         # Host :80 → high local ports
│   ├── local-dev-hosts.md          # Pattern A/B design
│   ├── sudoers.d-noizu-local-dev   # NOPASSWD lo0 / tee (macOS)
│   ├── profiles/noizu.yaml.example # tunnel-profile starter (k2l + l2k)
│   └── web/                        # daemon dashboard: index.html + server.py (loopback 4321)
├── test/                           # run-tests.sh (157 assertions) + fixtures (fake kubectl/ssh)
├── docs/
│   └── PROJ-ARCH · PROJ-LAYOUT · PROJ-SCHEMA · THREAT-MODEL (+ .summary companions)
├── Makefile                        # make install → ~/.local/bin + share (+ profile seed, web/)
├── README.md
├── AGENT.md / AGENTS.md / CLAUDE.md
└── merge-notes.md                  # branch-sweep history notes
```
