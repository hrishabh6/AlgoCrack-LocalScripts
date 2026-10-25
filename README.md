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
`EXECUTION_PLAYGROUND_ENABLED`, and `PLAYGROUND_UI_ENABLED` to `true`
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

Use `scripts/deployment/release-images.sh` to build, push, resume, and verify all **eight** AlgoCrack Docker images on Docker Hub:

| Image | Git source | Notes |
|---|---|---|
| `api-gateway` | AlgoCrack-APIGateway | Standard service image |
| `auth-service` | AlgoCrack-AuthService | Standard service image |
| `problem-service` | AlgoCrack-ProblemService | Standard service image |
| `submission-service` | AlgoCrack-SubmissionService | Standard service image |
| `code-execution-engine` | CodeExecutionEngine | CXE orchestrator (`Dockerfile`) |
| `cxe-nsjail-runner` | CodeExecutionEngine | Persistent runner (`Dockerfile.runner.packaged`, workspace context) |
| `frontend` | frontend | Standard service image |
| `waf` | docker | CRS edge image (`docker/waf`) |

Both CXE images record the **same** `CodeExecutionEngine` commit SHA. The runner build runs `:nsjail-runner:installDist` on the host and requires `scripts/.local/bin/nsjail` (Phase 1 native build).

**Prerequisites:** Docker, Buildx, Git, curl, Docker Hub authentication, host NsJail binary for runner publishes.

```bash
# Authenticate with Docker Hub
docker login -u hrishabhjoshi

# Preview builds without publishing (includes runner Gradle + Dockerfile path)
./scripts/deployment/release-images.sh v1.0.0-rc.8 --dry-run

# Build, push, and verify all eight images
./scripts/deployment/release-images.sh v1.0.0-rc.8 --yes

# Resume an interrupted release (skip already-published tags)
./scripts/deployment/release-images.sh v1.0.0-rc.8 --resume --yes

# Resume without immediate digest verification
./scripts/deployment/release-images.sh v1.0.0-rc.8 --resume --skip-verification --yes

# Verify all eight published images separately (uses manifest SHAs when present)
./scripts/deployment/release-images.sh v1.0.0-rc.8 --verify
```

**Manifest:** `release-manifests/<tag>/images.tsv` columns:

`component`, `image`, `git_repository`, `git_sha`, `platform`, `manifest_digest`, `status`, `dockerfile`, `build_context`, `artifact_role`

**Script features:**
- Validates clean Git repositories on `main` (CodeExecutionEngine checked once, used for orchestrator + runner).
- Builds sequentially for `linux/amd64` with immutable-tag preflight (HTTP 404 only → build).
- `--resume` skips remote tags that already exist; preserves manifest SHAs/digests for published rows.
- `--verify` inspects all eight remote digests; fails on digest drift vs a prior manifest.
- Does not modify Git branches or deploy Kubernetes.

**Helm alignment:** Chart image keys `images.codeExecutionEngine` and `nsjailRunner.image` map to `code-execution-engine:<tag>` and `cxe-nsjail-runner:<tag>`. RC overlays may add SHA-suffixed aliases (for example `v1.0.0-rc.8-cxe-c8e9c06`) for Minikube `pullPolicy: Never`; the release script publishes the canonical shared tag `v1.0.0-rc.N` on Docker Hub.

**Troubleshooting:**
- `Missing scripts/.local/bin/nsjail` — build/install Phase 1 NsJail before publishing the runner.
- `Gradle :nsjail-runner:installDist failed` — fix CXE runner module locally, then retry with `--resume`.
- `already exists; use --resume` — never overwrite a published RC tag; bump `rc.N` or resume.
- `Digest CHANGED` on `--verify` — tag was replaced upstream; treat as release incident, publish a new RC tag.

**Offline tests:**

```bash
bash scripts/deployment/tests/test_release_images.sh
```

**Note:** Use `--resume` after partial publishes. If verification was skipped, run `--verify` before Helm upgrade. Load images into Minikube (or pull after publish) before applying RC overlays with `pullPolicy: Never`.

### WAF and Kubernetes verification

```bash
# Manage scoped WAF exclusions.
scripts/deployment/apply-secrules.sh --help

# Validate generated Java compilation in an explicitly supplied CXE image.
scripts/verification/validate-java-k8s-compilation.sh <image>
```
