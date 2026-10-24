# AlgoCrack scripts

Scripts are grouped by operational purpose:

- `dev-local.sh` — stable primary entrypoint for the native development stack.
- `development/` — local bootstrap helpers called by `dev-local.sh`.
- `deployment/` — release-image and WAF deployment tooling.
- `maintenance/` — repository cleanup and code-inventory utilities.
- `verification/` — focused, non-production validation entrypoints.
- `nsjail/` — NsJail prerequisite, setup, and validation tooling.
- `experiments/` — reusable experiment fixtures and manifests.

Previously documented root command paths remain executable compatibility
wrappers. New documentation uses the purpose-based canonical paths. Generated
runtime files belong in `.local/` or `reports/` and are ignored; reusable
scripts, fixtures, and manifests remain tracked.

## Local development

```bash
scripts/dev-local.sh up
scripts/dev-local.sh status
scripts/dev-local.sh logs
scripts/dev-local.sh down
scripts/dev-local.sh observability
scripts/dev-local.sh bootstrap-potd   # after stack is up (Flyway V2/V3 applied)
```

After merging POTD, start the stack once so Auth/Problem Flyway runs, then:

```bash
scripts/dev-local.sh bootstrap-potd
# optional: POTD_ADMIN_EMAIL=you@example.com scripts/dev-local.sh bootstrap-potd
```

Verify: `curl -s http://localhost:9090/api/v1/daily-challenges/today`

### Google OAuth and a busy port 9090

Google OAuth callback URIs are exact. `dev-local.sh` normally uses port 9090,
but can choose a free fallback for non-OAuth local use. With real Google OAuth
credentials, it now stops before startup if the selected gateway port and
`GOOGLE_REDIRECT_URI` differ; silently switching the callback would cause
Google's `redirect_uri_mismatch` error.

Either free port 9090 and keep
`http://localhost:9090/api/v1/auth/login/oauth2/code/google`, or add the exact
fallback callback in Google Cloud Console's **Authorized redirect URIs** and
set matching `API_GATEWAY_PORT`, `NEXT_PUBLIC_API_BASE_URL`, and
`GOOGLE_REDIRECT_URI` values in `.env`.

`dev-local.sh` expects MySQL and Redis to already be running locally. It starts
each microservice and the frontend as separate live dev processes for an
IDE-style local workflow. It also generates local Prometheus/Loki/Alloy/Grafana
provisioning and can start those observability processes when the binaries are
installed. Grafana Explore uses the `Loki` datasource for application logs from
`.dev-logs/*.log`.

Before first use, copy the root environment template and set local credentials:

```bash
cp .env.example .env
```

The generated `.dev-logs/`, `.dev-pids/`, and `.dev-observability/` directories
are machine-local runtime state and are intentionally ignored by Git.

### Playground (local)

Playground is **on by default** when you run `scripts/dev-local.sh up`. The
launcher sets `PLAYGROUND_API_ENABLED`, `PLAYGROUND_RUN_ENABLED`,
`EXECUTION_PLAYGROUND_ENABLED`, and `NEXT_PUBLIC_PLAYGROUND_ENABLED` to `true`
and uses CXE sandbox backend `local-process` (trusted development only — not a
production or hostile-code sandbox). Production `application.yml` defaults and
the Kubernetes `production-verified` gate are unchanged.

Opt out:

```bash
DEV_LOCAL_PLAYGROUND=false scripts/dev-local.sh up
```

If you change playground or CXE backend configuration while services are
already running, `up` restarts the affected runner, submission, CXE, and
frontend processes once so flags take effect (see
`.dev-pids/dev-local-env.stamp`).

### Native CXE runner (Phase 4)

On supported Linux hosts, `scripts/dev-local.sh up` uses the persistent NsJail
runner for ordinary Java Run, official Submit, and oracle execution. It builds
the plain-Java runner distribution, starts it as a separate managed process,
waits for its Redis heartbeat, and then starts the rest of the local stack.
This path does not require Docker or Kubernetes. Playground remains on its
existing local development backend.

The launcher fails before starting application services if NsJail, Java 21, or
unprivileged user namespaces are unavailable. It never falls back from a
failed NsJail setup to unsandboxed execution. Install the pinned local NsJail
artifact first when needed:

```bash
scripts/nsjail/build-nsjail-from-docker.sh
scripts/nsjail/check-prerequisites.sh
scripts/dev-local.sh up
scripts/dev-local.sh status
scripts/dev-local.sh logs cxe-nsjail-runner
```

Runner workspaces, quarantine, and its task-local home default to narrowly
scoped `.dev-cxe-*` directories under the project root. `down` terminates the
runner process group before CXE shutdown; it does not stop MySQL or Redis.

The legacy local-process backend remains an explicit trusted-development
compatibility mode:

```bash
DEV_LOCAL_CXE_BACKEND=legacy-local-process scripts/dev-local.sh restart
```

Use that setting intentionally; missing or failed NsJail prerequisites never
select it automatically. Relevant overrides are `CXE_NSJAIL_BIN`,
`CXE_NSJAIL_LIB_DIR`, `CXE_V2_KEY_PREFIX`, `CXE_RUNNER_WORKSPACE_ROOT`, and
`CXE_RUNNER_QUARANTINE_ROOT`.


### CXE NsJail prerequisites (Phase 1)

Read-only gate and Minikube seccomp provisioning for the persistent NsJail
runner path. Phase 4 uses the native prerequisite gate; these tools do not
change Helm releases.

```bash
# Native gate (never enables local-process fallback)
scripts/nsjail/check-prerequisites.sh

# Build NsJail 3.6 + spike image; extract host binary to scripts/.local/
scripts/nsjail/build-nsjail-from-docker.sh

# Native fixture matrix (JDK 21)
scripts/nsjail/run-native-validation.sh

# Minikube Localhost seccomp (after minikube start)
scripts/nsjail/install-minikube-seccomp.sh
scripts/nsjail/verify-minikube-seccomp.sh
scripts/nsjail/run-minikube-validation.sh
```

Re-run install/verify after every Minikube delete/recreate or node replacement. Canary Pod manifest: `experiments/nsjail/pod-localhost-seccomp.yaml` (disposable namespace `algocrack-nsjail-spike`).

See `context/phase1/PHASE1_STATUS.md` and `scripts/nsjail/README.md`.

### Repository maintenance

Use the maintenance scripts to inspect code volume or safely remove local
branches that have already been merged into `main` across AlgoCrack
repositories.

```bash
scripts/maintenance/cloc.sh
scripts/maintenance/cloc_full.sh
scripts/maintenance/cleanup-merged-branches.sh
```

### Docker RC Image Build & Push

Use `scripts/deployment/release-images.sh` to build, push, resume, and verify all seven AlgoCrack Docker images (Gateway, Auth, Problem, Submission, CXE, Frontend, and WAF) on Docker Hub.

**Prerequisites:** Docker, Buildx, Git, curl, and Docker Hub authentication.

```bash
# Authenticate with Docker Hub
docker login -u hrishabhjoshi

# Preview builds without publishing
./scripts/deployment/release-images.sh v1.0.0-rc.2 --dry-run

# Build, push, and verify all images
./scripts/deployment/release-images.sh v1.0.0-rc.2

# Resume an interrupted release (skip already-published images)
./scripts/deployment/release-images.sh v1.0.0-rc.2 --resume

# Resume and push without immediate digest verification
./scripts/deployment/release-images.sh v1.0.0-rc.2 --resume --skip-verification

# Verify all seven published images separately
./scripts/deployment/release-images.sh v1.0.0-rc.2 --verify

# Skip interactive confirmation
./scripts/deployment/release-images.sh v1.0.0-rc.2 --yes
```

**Script features:**
- Validates clean Git repositories on `main`.
- Builds images sequentially for `linux/amd64`.
- Prevents overwriting existing Docker Hub tags.
- Supports resuming partially completed releases using `--resume`.
- Supports publishing without immediate verification using `--skip-verification`.
- Verifies all published images using `--verify`, without rebuilding.
- Generates a release manifest at `release-manifests/<tag>/images.tsv`.
- Does not modify Git branches or deploy Kubernetes.

**Note:** Use `--resume` if publishing was interrupted. Use a new RC tag when rebuilding or changing images; never overwrite an existing published RC. If verification is skipped, run `--verify` before Kubernetes deployment.

### WAF and Kubernetes verification

```bash
# Manage scoped WAF exclusions.
scripts/deployment/apply-secrules.sh --help

# Validate generated Java compilation in an explicitly supplied CXE image.
scripts/verification/validate-java-k8s-compilation.sh <image>
```
