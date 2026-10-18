#!/usr/bin/env python3
"""Safe, additive AlgoCrack WAF exclusion deployer (stdlib only).

The checked-in docker/waf/rules/REQUEST-900...conf is an always-on baseline.
New rules may be provided as docker/waf/exclusions/<CUSTOM_ID>.conf.
Enable/disable fragment IDs without editing this tool. Never disables arbitrary CRS rules.
"""
from __future__ import annotations

import argparse
import difflib
import fcntl
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

RULE_NAME = "REQUEST-900-EXCLUSION-RULES-BEFORE-CRS.conf"
CM_NAME = "algocrack-waf-exclusions"
WAF_PATH = "/opt/owasp-crs/rules/" + RULE_NAME
ID_PATTERN = re.compile(r"\bid\s*:\s*['\"]?(\d{5,10})\b", re.IGNORECASE)
SAFE_ID = re.compile(r"^[1-9]\d{4,9}$")
UNSAFE = re.compile(
    r"\b(?:SecRuleEngine|SecRuleRemoveById|SecRuleRemoveByTag|SecRuleRemoveByMsg|"
    r"SecRequestBodyAccess|SecResponseBodyAccess|Include|ctl\s*:\s*ruleEngine\s*=|"
    r"ctl\s*:\s*ruleRemoveBy(?:Id|Tag))\b", re.IGNORECASE
)
DOC_SEPARATOR = re.compile(r"(?m)^---\s*$")


class RuleError(Exception):
    pass


def note(s: str) -> None:
    print(s, flush=True)


def sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def cmd(args: list[str], *, timeout: int = 150, ok: bool = True, stdin: bytes | None = None) -> str:
    try:
        p = subprocess.run(args, input=stdin, capture_output=True, timeout=timeout, check=False)
    except (FileNotFoundError, subprocess.TimeoutExpired) as exc:
        raise RuleError(f"Command could not complete: {args[0]} ({exc})") from exc
    output = p.stdout.decode("utf-8", errors="replace")
    err = p.stderr.decode("utf-8", errors="replace")
    if ok and p.returncode:
        raise RuleError(f"Command failed (exit {p.returncode}): {' '.join(args[:5])}\n{(err or output)[-3500:]}")
    return output


def atomic_write(path: Path, data: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=".waf-rules-", dir=str(path.parent))
    try:
        with os.fdopen(fd, "wb") as f:
            f.write(data)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, path)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)


def rule_ids(text: str) -> list[str]:
    noncomments = "\n".join(line for line in text.splitlines() if not line.lstrip().startswith("#"))
    return ID_PATTERN.findall(noncomments)


def ensure_unique(ids: list[str], where: str) -> None:
    duplicates = sorted({item for item in ids if ids.count(item) > 1})
    if duplicates:
        raise RuleError(f"Duplicate SecRule IDs in {where}: {', '.join(duplicates)}")


def read_baseline(root: Path) -> tuple[str, set[str]]:
    path = root / "docker/waf/rules" / RULE_NAME
    if not path.is_file():
        raise RuleError(f"Missing canonical WAF baseline: {path}")
    data = path.read_text(encoding="utf-8")
    ids = rule_ids(data)
    ensure_unique(ids, str(path))
    if not ids:
        raise RuleError(f"No custom rule IDs found in {path}; refusing to replace existing WAF rules")
    return data.rstrip() + "\n", set(ids)


def discover_fragments(root: Path, baseline_ids: set[str]) -> dict[str, str]:
    directory = root / "docker/waf/exclusions"
    rules = {}
    for file in sorted(directory.glob("*.conf")):
        if not SAFE_ID.fullmatch(file.stem):
            raise RuleError(f"Fragment must be named <numeric-custom-ID>.conf: {file}")
        text = file.read_text(encoding="utf-8")
        ids = rule_ids(text)
        if ids != [file.stem]:
            raise RuleError(f"{file}: expected exactly one SecRule id:{file.stem}; found {ids}")
        if file.stem in baseline_ids:
            raise RuleError(f"{file.stem} is already in the baseline; delete duplicate fragment {file}")
        active = "\n".join(line for line in text.splitlines() if not line.lstrip().startswith("#"))
        if UNSAFE.search(active):
            raise RuleError(f"{file}: contains a prohibited global security directive")
        if not re.search(r"\bSecRule\b", text):
            raise RuleError(f"{file}: fragment must contain a SecRule")
        if "ruleRemoveTargetBy" not in text:
            raise RuleError(f"{file}: use targeted ruleRemoveTargetById/Tag; global disabling is forbidden")
        if not ("REQUEST_FILENAME" in text or "REQUEST_URI" in text):
            raise RuleError(f"{file}: rule must be scoped to an explicit request path")
        if "phase:1" not in text and "phase:2" not in text:
            raise RuleError(f"{file}: declare phase:1 or phase:2")
        rules[file.stem] = text.rstrip() + "\n"
    return rules


def state_file(root: Path) -> Path:
    return root / "docker/waf/exclusions/enabled.json"


def load_enabled(root: Path, fragment_ids: set[str]) -> set[str]:
    p = state_file(root)
    if not p.is_file():
        return set()
    try:
        raw = json.loads(p.read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        raise RuleError(f"Invalid enabled.json: {exc}") from exc
    if not isinstance(raw, dict) or set(raw) != {"enabled"} or not isinstance(raw["enabled"], list):
        raise RuleError("enabled.json must have only an 'enabled' string array")
    values = raw["enabled"]
    if any(not isinstance(x, str) or not SAFE_ID.fullmatch(x) for x in values):
        raise RuleError("enabled.json contains invalid IDs")
    if len(values) != len(set(values)):
        raise RuleError("enabled.json contains duplicate IDs")
    unknown = set(values) - fragment_ids
    if unknown:
        raise RuleError(f"Enabled fragment files are missing: {', '.join(sorted(unknown))}")
    return set(values)


def make_rules(baseline: str, fragments: dict[str, str], enabled: set[str]) -> bytes:
    result = baseline.rstrip() + "\n"
    for id_ in sorted(enabled, key=int):
        result += f"\n# Applied AlgoCrack exclusion {id_} (docker/waf/exclusions/{id_}.conf)\n"
        result += fragments[id_].rstrip() + "\n"
    return result.encode("utf-8")


def kube(args: argparse.Namespace, *sub: str) -> list[str]:
    return ["kubectl", "--context", args.context, *sub]


def helm_prefix(args: argparse.Namespace) -> list[str]:
    return ["helm"]


def check_context(args: argparse.Namespace) -> None:
    actual = cmd(["kubectl", "config", "current-context"]).strip()
    if actual != args.context:
        raise RuleError(f"Kubernetes current context is {actual!r}, expected {args.context!r}; select explicitly first")
    if args.context != "minikube" and not args.allow_nonlocal_context:
        raise RuleError("Refusing non-minikube deployment without --allow-nonlocal-context")
    if args.namespace != "algocrack" and not args.allow_nonlocal_context:
        raise RuleError("Refusing non-algocrack namespace without --allow-nonlocal-context")


def helm_values(args: argparse.Namespace) -> list[str]:
    ret = []
    for value in args.values:
        if not value.is_file():
            raise RuleError(f"Missing values file: {value}")
        ret.extend(["-f", str(value)])
    return ret


def split_resources(manifest: str) -> dict[tuple[str, str], str]:
    resources: dict[tuple[str, str], str] = {}
    for doc in DOC_SEPARATOR.split(manifest):
        cleaned = "\n".join(line.rstrip() for line in doc.splitlines()
                            if line.strip() and not line.lstrip().startswith("#"))
        if not cleaned:
            continue
        kind_m = re.search(r"(?m)^kind:\s*([\w.-]+)\s*$", cleaned)
        name_m = re.search(r"(?m)^metadata:\s*\n(?:^[ \t]+[^\n]*\n)*?^  name:\s*([^\s#]+)", cleaned)
        if not kind_m or not name_m:
            raise RuleError("Unable to identify a rendered resource; cannot enforce WAF-only change safety")
        key = (kind_m.group(1), name_m.group(1).strip('"\''))
        if key in resources:
            raise RuleError(f"Duplicate rendered resource: {key}")
        resources[key] = cleaned + "\n"
    return resources


def ensure_helm_wiring(chart: Path, rendered: str, candidate: bytes) -> None:
    cm = chart / "templates/waf-exclusions-configmap.yaml"
    deployment = chart / "templates/waf.yaml"
    if not cm.is_file() or not deployment.is_file():
        raise RuleError("Missing Helm WAF ConfigMap/Deployment templates. Follow README integration instructions")
    resources = split_resources(rendered)
    if ("ConfigMap", CM_NAME) not in resources or ("Deployment", "waf") not in resources:
        raise RuleError("Chart must render ConfigMap algocrack-waf-exclusions and Deployment waf")
    cm_text = resources[("ConfigMap", CM_NAME)]
    d_text = resources[("Deployment", "waf")]
    for needle in [RULE_NAME, *rule_ids(candidate.decode("utf-8"))]:
        if needle not in cm_text:
            raise RuleError(f"Rendered ConfigMap does not contain {needle}")
    for needle in ["name: waf-exclusions", "name: algocrack-waf-exclusions", "subPath: " + RULE_NAME, "mountPath: " + WAF_PATH]:
        if needle not in d_text:
            raise RuleError(f"Rendered WAF Deployment missing required mount configuration: {needle}")


def guard_manifest(old: str, new: str, *, allow_other: bool) -> bool:
    before = split_resources(old)
    after = split_resources(new)
    changes = [(key, "added" if key not in before else "removed" if key not in after else "changed")
               for key in sorted(set(before) | set(after)) if before.get(key) != after.get(key)]
    if changes:
        note("Rendered Helm resource changes:")
        for (kind, name), action in changes:
            note(f"  {action.upper():7} {kind}/{name}")
    else:
        note("Rendered Helm manifests unchanged.")
    unsafe = [(k, a) for k, a in changes if k not in {("ConfigMap", CM_NAME), ("Deployment", "waf")}]
    if unsafe and not allow_other:
        raise RuleError("Refusing unrelated Helm resource changes. Fix chart/values drift or use --allow-other-changes intentionally")
    return bool(changes)


def get_helm_status(args: argparse.Namespace) -> dict:
    raw = cmd(["helm", "status", args.release, "--kube-context", args.context, "-n", args.namespace, "-o", "json"])
    try:
        obj = json.loads(raw)
        status = obj.get("info", {}).get("status", "unknown")
        if status != "deployed":
            raise RuleError(f"Helm release {args.release} status={status!r}, expected deployed. Repair release before applying rules")
        if not isinstance(obj.get("version"), int):
            raise RuleError("Helm status lacks a numeric revision")
        return obj
    except ValueError as exc:
        raise RuleError(f"Could not parse Helm status: {exc}") from exc


def runtime_rules(args: argparse.Namespace) -> bytes:
    return subprocess.run(
        kube(args, "exec", "-n", args.namespace, "deployment/waf", "-c", "waf", "--", "cat", WAF_PATH),
        capture_output=True, check=True, timeout=35
    ).stdout


def check_runtime(args: argparse.Namespace, candidate: bytes) -> None:
    cmd(kube(args, "rollout", "status", "deployment/waf", "-n", args.namespace, "--timeout=180s"), timeout=205)
    cmd(kube(args, "exec", "-n", args.namespace, "deployment/waf", "-c", "waf", "--", "nginx", "-t"), timeout=45)
    remote = runtime_rules(args)
    if sha(remote) != sha(candidate):
        raise RuleError(f"WAF mounted file SHA mismatch: expected {sha(candidate)[:12]}, got {sha(remote)[:12]}")
    note("WAF passed rollout, nginx -t and mounted file SHA-256 verification.")


def docker_validate(args: argparse.Namespace, staged: Path, rendered: str) -> None:
    if args.docker_check == "skip":
        note("WARNING: Container-level NGINX/ModSecurity preflight explicitly skipped.")
        return
    if not shutil.which("docker"):
        if args.docker_check == "require":
            raise RuleError("Docker not installed; --docker-check=require needs it")
        note("NOTE: Docker not found. Only static/Helm checks run pre-deployment; nginx -t runs after rollout.")
        return
    resources = split_resources(rendered)
    d = resources[("Deployment", "waf")]
    m = re.search(r"(?m)^\s+image:\s*(\S+)", d)
    if not m:
        raise RuleError("Cannot determine WAF image for Docker validation")
    image = m.group(1).strip('"\'')
    inspect = subprocess.run(["docker", "image", "inspect", image], capture_output=True, timeout=25)
    if inspect.returncode:
        if args.docker_check == "require":
            raise RuleError(f"WAF image {image} not available in local Docker cache; pull it or use --docker-check=auto")
        note(f"NOTE: WAF image {image} not in local Docker cache; nginx -t will be checked post-deployment.")
        return
    source = staged / "files/waf" / RULE_NAME
    note("Validating WAF NGINX+ModSecurity syntax in an isolated local container...")
    cmd(["docker", "run", "--rm", "--pull=never", "--network=none",
         "-e", "BACKEND=http://127.0.0.1:9090", "-e", "SERVER_NAME=localhost",
         "-e", "PORT=8080", "-e", "MODSEC_RULE_ENGINE=On",
         "-v", f"{source}:{WAF_PATH}:ro", image, "nginx", "-t"], timeout=120)
    note("Local WAF container syntax check passed.")


def run_smoke(args: argparse.Namespace) -> None:
    """Caller-owned smoke test: can cover future OAuth, submission, and run flows."""
    note(f"Running optional application smoke test: {args.smoke_script.name}")
    env = os.environ.copy()
    env.update(ALGOCRACK_KUBE_CONTEXT=args.context, ALGOCRACK_NAMESPACE=args.namespace,
               ALGOCRACK_HELM_RELEASE=args.release)
    try:
        test = subprocess.run([str(args.smoke_script)], env=env, capture_output=True,
                              text=True, timeout=180, check=False)
    except subprocess.TimeoutExpired as exc:
        raise RuleError("Application smoke test timed out after 180s") from exc
    if test.returncode:
        raise RuleError(f"Application smoke test failed (exit {test.returncode}); "
                        "inspect the test locally. Sensitive output is intentionally not echoed.")
    note("Application smoke test passed.")


def rollback(args: argparse.Namespace, previous_revision: int) -> None:
    note(f"Attempting automatic Helm rollback to revision {previous_revision}...")
    try:
        cmd(["helm", "rollback", args.release, str(previous_revision), "--kube-context", args.context, "-n", args.namespace,
             "--wait", "--timeout", args.timeout], timeout=900)
        cmd(kube(args, "rollout", "restart", "deployment/waf", "-n", args.namespace), timeout=45)
        cmd(kube(args, "rollout", "status", "deployment/waf", "-n", args.namespace, "--timeout=180s"), timeout=205)
        note("Rollback completed. Check Helm status and WAF logs before retrying.")
    except Exception as exc:
        note(f"CRITICAL: Automatic rollback failed: {exc}")
        note(f"Manual recovery: helm rollback {args.release} {previous_revision} -n {args.namespace} --wait")


def show_list(baseline_ids: set[str], fragments: dict[str, str], enabled: set[str]) -> None:
    note("ID          STATUS       SOURCE")
    for id_ in sorted(baseline_ids | set(fragments), key=int):
        mode = "baseline" if id_ in baseline_ids else "enabled" if id_ in enabled else "available"
        origin = f"docker/waf/rules/{RULE_NAME}" if id_ in baseline_ids else f"docker/waf/exclusions/{id_}.conf"
        note(f"{id_:<11} {mode:<12} {origin}")
    note("Baseline IDs are always included. To toggle an individual rule, create a reviewed fragment file instead.")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        prog="apply-secrules.sh",
        description="Validate and apply reviewed, narrowly scoped AlgoCrack WAF exclusions. Positional IDs enable rules.")
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--list", action="store_true", help="List baseline and fragment IDs (offline)")
    mode.add_argument("--status", action="store_true", help="Compare local desired file and running WAF (read-only)")
    mode.add_argument("--disable", action="store_true", help="Disable listed fragment IDs (baseline cannot be disabled)")
    mode.add_argument("--validate", action="store_true", help="Validate currently enabled configuration without deploying")
    parser.add_argument("ids", nargs="*", metavar="ID", help="One or more approved AlgoCrack exclusion IDs")
    parser.add_argument("--all", action="store_true", help="Enable all reviewed fragment files")
    parser.add_argument("--dry-run", action="store_true", help="Plan and validate, never modify local files or Kubernetes")
    parser.add_argument("--offline", action="store_true", help="With --dry-run/--validate, skip Kubernetes context and release checks")
    parser.add_argument("--force", action="store_true", help="Upgrade/restart even when there is no detectable change")
    parser.add_argument("--allow-other-changes", action="store_true", help="Permit Helm changes outside WAF Deployment/ConfigMap (risky)")
    parser.add_argument("--allow-nonlocal-context", action="store_true", help="Allow deployment to a context/namespace other than local Minikube")
    parser.add_argument("--docker-check", choices=["auto", "require", "skip"], default="auto", help="NGINX syntax preflight using locally cached WAF image")
    parser.add_argument("--smoke-script", type=Path, help="Optional executable application smoke-test after deploy; nonzero exit triggers rollback")
    parser.add_argument("--repo-root", type=Path, help="Override repository root (default parent of scripts/)")
    parser.add_argument("--chart", type=Path, help="Override Helm chart directory")
    parser.add_argument("-f", "--values", type=Path, action="append", help="Helm values YAML; repeatable (default RC2 local-prod-sim overlay)")
    parser.add_argument("-n", "--namespace", default="algocrack")
    parser.add_argument("--release", default="algocrack")
    parser.add_argument("--context", default="minikube")
    parser.add_argument("--timeout", default="10m", help="Helm rollout timeout (e.g. 10m)")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if not re.fullmatch(r"[1-9]\d*[smh]", args.timeout):
        raise RuleError("--timeout must be a positive duration such as 10m")
    dns_name = re.compile(r"^[a-z0-9](?:[-a-z0-9]*[a-z0-9])?$")
    if not dns_name.fullmatch(args.namespace) or not dns_name.fullmatch(args.release):
        raise RuleError("--namespace and --release must be valid lowercase Kubernetes DNS names")
    args.root = (args.repo_root or Path(__file__).resolve().parent.parent).resolve()
    args.chart = (args.chart or (args.root / "helm/algocrack")).resolve()
    args.values = [x.resolve() for x in (args.values or [args.root / "helm/algocrack/values.local-prod-sim-rc2.yaml"])]
    if args.smoke_script:
        args.smoke_script = args.smoke_script.resolve()
        if not args.smoke_script.is_file() or not os.access(args.smoke_script, os.X_OK):
            raise RuleError(f"Smoke script must exist and be executable: {args.smoke_script}")
    if not args.list and not args.chart.is_dir():
        raise RuleError(f"Missing Helm chart at {args.chart}; copy scripts/ into your AlgoCrack repository")
    if args.offline and not (args.dry_run or args.validate):
        raise RuleError("--offline is allowed only with --dry-run or --validate")
    if args.disable and not args.ids:
        raise RuleError("--disable requires one or more IDs")
    if args.all and (args.ids or args.disable or args.list or args.status):
        raise RuleError("--all cannot be combined with IDs, --disable, --list or --status")
    if (args.list or args.status or args.validate) and args.ids:
        raise RuleError("This mode does not accept positional IDs")
    if not args.list and not args.status and not args.validate and not args.ids and not args.all:
        raise RuleError("Supply custom rule IDs, --all, --list, --status or --validate")
    if any(not SAFE_ID.fullmatch(id_) for id_ in args.ids):
        raise RuleError("Rule IDs must be 5–10 digit positive numeric IDs")
    if len(args.ids) != len(set(args.ids)):
        raise RuleError("Duplicate positional ID")

    baseline, baseline_ids = read_baseline(args.root)
    fragments = discover_fragments(args.root, baseline_ids)
    enabled = load_enabled(args.root, set(fragments))
    if args.list:
        show_list(baseline_ids, fragments, enabled)
        return 0
    if args.status:
        desired = make_rules(baseline, fragments, enabled)
        target = args.chart / "files/waf" / RULE_NAME
        note(f"Desired rules SHA: {sha(desired)}")
        local_ok = target.is_file() and target.read_bytes() == desired
        note(f"Chart copy: {'MATCH' if local_ok else 'OUT OF SYNC'}")
        check_context(args)
        note(f"Helm status: {get_helm_status(args)['info']['status']}")
        runtime_ok = sha(runtime_rules(args)) == sha(desired)
        note(f"Mounted WAF rules: {'MATCH' if runtime_ok else 'OUT OF SYNC'}")
        return 0 if local_ok and runtime_ok else 2

    unknown = set(args.ids) - baseline_ids - set(fragments)
    if unknown:
        raise RuleError(f"Unknown IDs: {', '.join(sorted(unknown))}. Put reviewed rules in docker/waf/exclusions/<ID>.conf")
    next_enabled = set(enabled)
    if args.disable:
        forbidden = set(args.ids) & baseline_ids
        if forbidden:
            raise RuleError(f"Cannot disable always-on baseline rules: {', '.join(sorted(forbidden))}")
        next_enabled.difference_update(args.ids)
    elif args.all:
        next_enabled.update(fragments)
    else:
        next_enabled.update(set(args.ids) & set(fragments))
    candidate = make_rules(baseline, fragments, next_enabled)
    ids = rule_ids(candidate.decode())
    ensure_unique(ids, "combined rules")
    note(f"Candidate includes {len(ids)} custom rules. SHA-256: {sha(candidate)}")
    if args.disable:
        note("Disabling only requested fragments; baseline exclusions remain active.")
    args.dry_run = args.dry_run or args.validate

    lock_path = Path(tempfile.gettempdir()) / f"algocrack-waf-{re.sub('[^a-zA-Z0-9_-]', '_', args.context)}-{args.namespace}-{args.release}.lock"
    with open(lock_path, "w", encoding="utf-8") as lock:
        try:
            fcntl.flock(lock.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as exc:
            raise RuleError("Another WAF rule operation is already running; retry after it finishes") from exc
        if not shutil.which("helm"):
            raise RuleError("Helm CLI is required")
        if not args.offline:
            check_context(args)
        with tempfile.TemporaryDirectory(prefix="algocrack-waf-stage-") as tmp:
            staged = Path(tmp) / "algocrack"
            shutil.copytree(args.chart, staged)
            staged_file = staged / "files/waf" / RULE_NAME
            staged_file.parent.mkdir(parents=True, exist_ok=True)
            staged_file.write_bytes(candidate)
            note("Running Helm lint and template rendering...")
            values = helm_values(args)
            cmd(["helm", "lint", str(staged), *values], timeout=120)
            rendered = cmd(["helm", "template", args.release, str(staged), "-n", args.namespace,
                            "--no-hooks", *values], timeout=120)
            ensure_helm_wiring(staged, rendered, candidate)
            docker_validate(args, staged, rendered)

            previous_revision = None
            manifest_changed = True
            if not args.offline:
                status = get_helm_status(args)
                previous_revision = status["version"]
                old_manifest = cmd(["helm", "get", "manifest", args.release, "--kube-context", args.context, "-n", args.namespace], timeout=100)
                manifest_changed = guard_manifest(old_manifest, rendered, allow_other=args.allow_other_changes)
            else:
                note("OFFLINE: Live release and non-WAF manifest drift checks were not run.")

            chart_copy = args.chart / "files/waf" / RULE_NAME
            local_sync = not chart_copy.is_file() or chart_copy.read_bytes() != candidate
            state_sync = enabled != next_enabled
            if args.dry_run:
                if args.smoke_script:
                    note("NOTE: Application smoke script is not executed during --dry-run.")
                note("DRY RUN: No repository files or Kubernetes resources were changed.")
                note(f"Planned: chart source sync={local_sync}, enabled-state update={state_sync}, Helm manifest changes={manifest_changed}")
                return 0

            runtime_equal = False
            try:
                runtime_equal = sha(runtime_rules(args)) == sha(candidate)
            except (subprocess.CalledProcessError, subprocess.TimeoutExpired, OSError):
                note("WARNING: Could not read live WAF rules; will verify after upgrade.")
            if not manifest_changed and runtime_equal and not args.force:
                note("No Helm/WAF changes required. Synchronizing local chart copy if necessary.")
                if local_sync:
                    atomic_write(chart_copy, candidate)
                if state_sync:
                    atomic_write(state_file(args.root), (json.dumps({"enabled": sorted(next_enabled, key=int)}, indent=2) + "\n").encode())
                if args.smoke_script:
                    run_smoke(args)
                return 0

            note("Deploying via Helm (only WAF resources should differ)...")
            changed_remote = False
            try:
                changed_remote = True
                cmd(["helm", "upgrade", args.release, str(staged), "--kube-context", args.context, "-n", args.namespace,
                     "--take-ownership", "--server-side=false", *values,
                     "--wait", "--timeout", args.timeout], timeout=900)
                # subPath mounts are not refreshed on ConfigMap updates alone.
                runtime_equal = sha(runtime_rules(args)) == sha(candidate)
                if not runtime_equal or args.force:
                    note("Restarting WAF only (ConfigMap subPath requires restart)...")
                    cmd(kube(args, "rollout", "restart", "deployment/waf", "-n", args.namespace), timeout=45)
                check_runtime(args, candidate)
                if args.smoke_script:
                    run_smoke(args)
            except Exception:
                if changed_remote and previous_revision is not None:
                    rollback(args, previous_revision)
                raise

            if local_sync:
                atomic_write(chart_copy, candidate)
            if state_sync:
                atomic_write(state_file(args.root), (json.dumps({"enabled": sorted(next_enabled, key=int)}, indent=2) + "\n").encode())
            note("SUCCESS: Helm WAF exclusion deployment verified. Existing images and other workloads preserved.")
            note("Application smoke tests are still required; WAF acceptance alone does not guarantee code execution or OAuth success.")
            return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (RuleError, OSError, subprocess.CalledProcessError, subprocess.TimeoutExpired) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        sys.exit(1)
