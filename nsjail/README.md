# NsJail prerequisite tooling

Pinned versions and hashes live in `lib/constants.sh`.

- `check-prerequisites.sh` — fail-fast native diagnostic.
- `build-nsjail-from-docker.sh` — build `algocrack/nsjail-spike:3.6` and
  extract host `nsjail` plus runtime libraries into `scripts/.local/`.
- `run-native-fixture.sh` — run one NsJail fixture on the host.
- `run-native-validation.sh` — run the Java/security fixture matrix.
- `install-minikube-seccomp.sh` — copy the pinned outer profile to the
  Minikube kubelet.
- `verify-minikube-seccomp.sh` — verify the profile hash and Hello canary.
- `run-minikube-validation.sh` — run the Minikube canary matrix.
- `capture-host-state.sh` — capture kernel, user-namespace, and cgroup state.

Compatibility wrappers for the three previously documented root entrypoints
remain in the parent `scripts/` directory.

Experiment fixtures and manifests: `../experiments/nsjail/`.
