# Threat Model — Summary

Local-dev laptop tool: tunnels cluster data services onto loopback with the
operator's own kubectl/ssh authority; opt-in l2k reverse tunnels expose local
ports to the cluster. Stores no secrets. Full model: [THREAT-MODEL.md](THREAT-MODEL.md).

## Trust boundaries

- Host loopback ↔ web API (`127.0.0.1:4321`, regex + CLI re-validated mutations)
- Laptop ↔ cluster k2l (kubectl, operator RBAC)
- Laptop ↔ cluster l2k (`ssh -N -R`, GatewayPorts, opt-in)
- Tool ↔ host network config (digest-pinned sudoers: `ifconfig lo0`, `tee /etc/hosts`)

## Register (9 items)

| Severity | Count | Items |
|----------|-------|-------|
| Mitigated | 6 | T-003 (l2k exposure — opt-in + doctor checks), T-004 (sudo digest pinning), T-005 (backoff), T-007 (context/doctor), T-008 (no-deps supply chain, fake-cluster tests), T-009 (local-only logging, accepted-class) |
| Accepted | 2 | T-002 (local processes can drive API — privilege ≤ operator's own), T-006 (state-file topology visibility) |
| Open | 1 | **T-001 — web API lacks Origin/Host validation: browser CSRF can mutate tunnels; suggested fix: allowlist or request token** |

## Residual risk

l2k ports reachable by cluster workloads while up; drive-by CSRF can mutate
(persist) local tunnel rows but exfiltrate nothing; `/tmp` state fallback
visible to local users (topology only, no creds).
