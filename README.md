# Local Development

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

If you change playground-related env while services are already running, `up`
restarts submission-service, code-execution-engine, and frontend once so flags
take effect (see `.dev-pids/playground-local-env.stamp`).


### Clean Up Merged Git Branches

Use `cleanup-merged-branches.sh` to safely remove local branches that have already been merged into `main` across AlgoCrack repositories.

```bash
chmod +x cleanup-merged-branches.sh
./cleanup-merged-branches.sh

### Docker RC Image Build & Push

Use `scripts/release-images.sh` to build, push, resume, and verify all seven AlgoCrack Docker images (Gateway, Auth, Problem, Submission, CXE, Frontend, and WAF) on Docker Hub.

**Prerequisites:** Docker, Buildx, Git, curl, and Docker Hub authentication.

```bash
# Authenticate with Docker Hub
docker login -u hrishabhjoshi

# Preview builds without publishing
./scripts/release-images.sh v1.0.0-rc.2 --dry-run

# Build, push, and verify all images
./scripts/release-images.sh v1.0.0-rc.2

# Resume an interrupted release (skip already-published images)
./scripts/release-images.sh v1.0.0-rc.2 --resume

# Resume and push without immediate digest verification
./scripts/release-images.sh v1.0.0-rc.2 --resume --skip-verification

# Verify all seven published images separately
./scripts/release-images.sh v1.0.0-rc.2 --verify

# Skip interactive confirmation
./scripts/release-images.sh v1.0.0-rc.2 --yes
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
