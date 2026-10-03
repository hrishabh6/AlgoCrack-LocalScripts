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
