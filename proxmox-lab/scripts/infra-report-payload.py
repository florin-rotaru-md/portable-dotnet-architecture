#!/usr/bin/env python3
"""Versioned ingest payload. Does not execute probes or infer metrics from prose."""
import json
import sys


def payload(host, script, exit_code, time_observed, output, records):
    groups = {}
    complete = False
    ranks = {"pass": 0, "warn": 1, "fail": 2}
    for line in records.splitlines():
        if line == "@complete":
            complete = True
            continue
        if line.startswith("@json\t"):
            result = json.loads(line.split("\t", 1)[1])
            if result["check"] in groups:
                raise ValueError("duplicate structured check")
            result["resource"] = host
            groups[result["check"]] = result
            continue
        key, category, status, observation, advisory, detail = line.split("\t", 5)
        if status not in ranks or observation not in {"observed", "unknown", "notApplicable"}:
            raise ValueError("invalid check record")
        group = groups.setdefault(key, {
            "check": key, "category": category, "resource": host, "status": "pass",
            "observation": observation, "advisory": advisory == "true", "detail": "", "metrics": [],
        })
        if group["category"] != category:
            raise ValueError("check changed category")
        if ranks[status] > ranks[group["status"]]:
            group["status"] = status
        if observation == "unknown":
            group["observation"] = observation
        elif observation == "observed" and group["observation"] == "notApplicable":
            group["observation"] = "observed"
        group["advisory"] = group["advisory"] and advisory == "true"
        group.setdefault("details", []).append((ranks[status], detail))
    for group in groups.values():
        if "details" in group:
            group["detail"] = "; ".join(d for _, d in sorted(group.pop("details"), key=lambda item: -item[0]))[:2000]
    if script in {"cluster-health", "backup-verify"} and not complete:
        groups["collector"] = {
            "check": "collector", "category": "monitoring", "resource": host,
            "status": "warn", "observation": "unknown", "metrics": [],
            "detail": "collector did not confirm completion; some checks may not have run",
        }
    if len(groups) > 100:
        raise ValueError("too many checks; refusing to drop evidence")
    if not groups and script in {"pve-config-backup", "r2-backup"}:
        groups["process"] = {
            "check": "process", "category": "monitoring", "resource": host,
            "status": "fail" if exit_code else "pass", "observation": "observed",
            "detail": f"{script} exited {exit_code}; archive coverage is evaluated by backup-verify",
            "metrics": [],
        }
    lines = [line[:512] for line in output.splitlines() if line.strip()]
    lines.sort(key=lambda line: 0 if "[FAIL" in line else 1 if "[WARN" in line else 2)
    return {
        "schemaVersion": 2, "host": host, "script": script, "exitCode": exit_code,
        "timeObserved": time_observed, "lines": lines[:200], "checks": list(groups.values()),
    }


if __name__ == "__main__":
    with open(sys.argv[5], encoding="utf-8") as sidecar:
        records = sidecar.read()
    print(json.dumps(payload(sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4], sys.stdin.read(), records)))
