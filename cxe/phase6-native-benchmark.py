#!/usr/bin/env python3
"""Reproducible native Phase 6 Run/Submit benchmark and parity probe.

Uses only the public Submission Service API and records verdict/timing metadata;
source, test output, compiler output, and Redis payloads are never persisted.
"""
from __future__ import annotations

import argparse
import json
import statistics
import time
import urllib.error
import urllib.request
import uuid
from pathlib import Path


TERMINAL = {"COMPLETED", "FAILED", "CANCELLED"}


def request(base: str, method: str, path: str, body: dict | None = None) -> tuple[int, dict]:
    data = json.dumps(body).encode() if body else None
    req = urllib.request.Request(
        base + path,
        data=data,
        method=method,
        headers={"Content-Type": "application/json", "X-User-Id": "phase6-validation"},
    )
    try:
        with urllib.request.urlopen(req, timeout=180) as response:
            return response.status, json.loads(response.read() or b"{}")
    except urllib.error.HTTPError as error:
        return error.code, json.loads(error.read() or b"{}")


def percentile(values: list[float], fraction: float) -> float:
    rank = max(0, min(len(values) - 1, int((len(values) * fraction) + 0.999999) - 1))
    return sorted(values)[rank]


def one_run(base: str, code: str, question_id: int) -> dict:
    started = time.perf_counter()
    status, body = request(base, "POST", "/api/v1/submissions/run", {"language": "java", "code": code, "questionId": question_id})
    return {"httpStatus": status, "verdict": body.get("verdict"), "elapsedMs": round((time.perf_counter() - started) * 1000, 1)}


def one_submit(base: str, code: str, question_id: int) -> dict:
    started = time.perf_counter()
    status, body = request(base, "POST", "/api/v1/submissions", {"language": "java", "code": code, "questionId": question_id})
    submission_id = body.get("submissionId")
    final = {}
    if status == 202 and submission_id:
        deadline = time.monotonic() + 180
        while time.monotonic() < deadline:
            _, final = request(base, "GET", f"/api/v1/submissions/{submission_id}")
            if final.get("status") in TERMINAL:
                break
            time.sleep(0.05)
    return {
        "httpStatus": status,
        "submissionStatus": final.get("status"),
        "verdict": final.get("verdict"),
        "elapsedMs": round((time.perf_counter() - started) * 1000, 1),
        "submissionId": submission_id,
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--base-url", default="http://127.0.0.1:8080")
    parser.add_argument("--fixture", type=Path, required=True)
    parser.add_argument("--question-id", type=int, default=1)
    parser.add_argument("--flow", choices=("run", "submit"), required=True)
    parser.add_argument("--warmup", type=int, default=5)
    parser.add_argument("--count", type=int, default=100)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    code = args.fixture.read_text()
    invoke = one_run if args.flow == "run" else one_submit
    for _ in range(args.warmup):
        invoke(args.base_url, code, args.question_id)
    samples = [invoke(args.base_url, code, args.question_id) for _ in range(args.count)]
    expected = "PASSED_RUN" if args.flow == "run" else "ACCEPTED"
    failures = [sample for sample in samples if sample["verdict"] != expected]
    times = [sample["elapsedMs"] for sample in samples]
    document = {
        "runId": str(uuid.uuid4()), "flow": args.flow, "count": args.count,
        "warmup": args.warmup, "expectedVerdict": expected, "failures": len(failures),
        "summaryMs": {"min": min(times), "p50": percentile(times, .50), "p95": percentile(times, .95), "p99": percentile(times, .99), "max": max(times), "mean": round(statistics.mean(times), 1)},
        "samples": samples,
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(document, indent=2) + "\n")
    print(json.dumps({key: document[key] for key in ("flow", "count", "failures", "summaryMs")}))
    if failures:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
