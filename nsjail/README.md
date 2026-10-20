# NsJail prerequisite tooling

Pinned versions and hashes live in `lib/constants.sh`.

| Script | Purpose |
| --- | --- |
| `build-nsjail-from-docker.sh` | Build `algocrack/nsjail-spike:3.6` and extract host `nsjail` + runtime libs into `scripts/.local/` |
| `run-native-fixture.sh` | Single-fixture NsJail invocation on the host (Ubuntu OpenJDK 21 layout) |
| `run-native-validation.sh` | Java/security fixture matrix → `context/phase1/native-validation.jsonl` |
| `run-minikube-validation.sh` | Canary Pod matrix → `context/phase1/minikube-validation.jsonl` |
| `capture-host-state.sh` | Kernel/userns/cgroup snapshot |

Parent repo scripts:

- `../check-nsjail-prerequisites.sh` — fail-fast diagnostic
- `../install-minikube-nsjail-seccomp.sh` — copy pinned outer profile to kubelet
- `../verify-minikube-nsjail-seccomp.sh` — hash check + Hello canary

Experiment fixtures and manifests: `../experiments/nsjail/`.
