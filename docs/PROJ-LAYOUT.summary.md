# Project Layout — Summary

Supervised k8s port-forwards + local-dev hosts/aliases fabric.
Full annotated tree: [PROJ-LAYOUT.md](PROJ-LAYOUT.md).

```
port-forward-utils/
├── bin/
│   └── cluster-port-forward        # start · watch · stop · status · list · doctor · hosts · aliases
├── share/
│   ├── port-forwards.catalog       # PF targets + profiles + optional bind_ip
│   ├── hosts.local-dev             # *.dev → 10.0.0.x block
│   ├── Caddyfile.local-dev         # Host :80 → high local ports
│   ├── local-dev-hosts.md          # Pattern A/B design
│   └── sudoers.d-noizu-local-dev   # NOPASSWD lo0 / tee (macOS)
├── docs/
│   └── PROJ-LAYOUT.md · PROJ-LAYOUT.summary.md
├── Makefile                        # make install → ~/.local/bin + share
└── README.md
```
