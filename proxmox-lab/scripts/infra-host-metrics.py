#!/usr/bin/env python3
"""Read-only local measurements for cluster-health; no package refresh or sensor configuration."""
import json
import math
import os
from pathlib import Path
import re
import subprocess
import sys
import time


def check(key, category, status, detail, metrics=None, observation="observed", advisory=False):
    return dict(check=key, category=category, status=status, detail=detail[:2000],
                observation=observation, advisory=advisory, metrics=metrics or [])


def metric(key, value, unit, resource=None, warning=None, failure=None):
    return dict(key=key, value=value, unit=unit, resource=resource,
                warningAbove=warning, failureAbove=failure)


def command(args, timeout=15):
    return subprocess.run(args, capture_output=True, text=True, timeout=timeout,
                          env={**os.environ, "LC_ALL": "C"}, check=False)


def temperatures(document):
    metrics = []
    rank = 0
    unknown = False
    for chip, sensors in document.items():
        if not isinstance(sensors, dict):
            continue
        for name, values in sensors.items():
            if not isinstance(values, dict):
                continue
            for key, value in values.items():
                if not re.fullmatch(r"temp\d+_input", key):
                    continue
                if not isinstance(value, (int, float)) or not math.isfinite(value):
                    unknown = True
                    continue
                stem = key.removesuffix("_input")
                high, critical = values.get(stem + "_max"), values.get(stem + "_crit")
                high = high if isinstance(high, (float, int)) and math.isfinite(high) and high > 0 else None
                critical = critical if isinstance(critical, (float, int)) and math.isfinite(critical) and critical > 0 else None
                unknown |= high is None and critical is None
                if (critical is not None and value >= critical) or values.get(stem + "_crit_alarm") == 1:
                    rank = 2
                elif (high is not None and value >= high) or values.get(stem + "_max_alarm") == 1:
                    rank = max(rank, 1)
                metrics.append(metric("temperature", value, "°C", f"{chip}/{name}", high, critical))
    if not metrics:
        return check("temperatures", "temperatures", "warn", "no temperature readings returned", observation="unknown")
    if len(metrics) > 64:
        raise ValueError("more than 64 temperature readings; refusing to drop evidence")
    return check("temperatures", "temperatures", ["pass", "warn", "fail"][max(rank, int(unknown))],
                 f"{len(metrics)} temperature readings; " + ("some hardware limits unavailable" if unknown else "hardware limits evaluated"),
                 metrics, "unknown" if unknown else "observed")


def temperature_probe():
    result = command(["sensors", "-j"])
    if result.returncode:
        raise ValueError("sensors failed; temperatures unavailable")
    return temperatures(json.loads(result.stdout))


def services_probe():
    result = command(["systemctl", "--failed", "--no-legend", "--plain", "--no-pager"])
    if result.returncode:
        raise ValueError("systemctl failed; unit state unavailable")
    units = [line.split()[0] for line in result.stdout.splitlines() if line.strip()]
    return check("failed-services", "host", "warn" if units else "pass",
                 "failed units: " + (", ".join(units) if units else "none"),
                 [metric("failed-services", len(units), "count", warning=0)])


def ping_result(output, returncode, peer):
    sample = re.search(r"(\d+) packets transmitted, (\d+) received,.*?([\d.]+)% packet loss", output)
    if returncode not in (0, 1) or not sample or int(sample[1]) == 0:
        raise ValueError("ping did not return a valid sample")
    sent, received, loss = int(sample[1]), int(sample[2]), float(sample[3])
    if received > sent or not 0 <= loss <= 100:
        raise ValueError("ping returned an inconsistent sample")
    metrics = [metric("packet-loss", loss, "%", peer, 0, 100), metric("ping-count", sent, "count", peer)]
    status = "fail" if received == 0 else "warn" if loss > 0 else "pass"
    rtt = re.search(r"=\s*[\d.]+/([\d.]+)/[\d.]+/[\d.]+ ms", output)
    if received:
        if not rtt:
            raise ValueError("ping received replies but did not return RTT")
        average = float(rtt[1])
        metrics.append(metric("latency", average, "ms", peer, 2, 5))
        if average >= 5:
            status = "fail"
        elif average >= 2 and status == "pass":
            status = "warn"
    return check("lan-sample", "network", status, f"LAN sample to {peer}: {received}/{sent} replies, {loss}% loss", metrics)


def network_probe():
    peer = os.environ.get("INFRA_PEER_ADDRESS", "")
    if not peer or not re.fullmatch(r"[a-zA-Z0-9][a-zA-Z0-9.:-]*", peer):
        raise ValueError("set INFRA_PEER_ADDRESS to the peer's LAN address in /etc/infra-report.conf")
    result = command(["ping", "-n", "-q", "-c", "20", "-i", "0.2", "-w", "10", "--", peer])
    return ping_result(result.stdout, result.returncode, peer)


def updates_probe():
    # Reading cached lists cannot prove that there are no updates when the cache is absent/stale.
    stamp = Path("/var/lib/apt/periodic/update-success-stamp")
    lists = list(Path("/var/lib/apt/lists").glob("*_InRelease"))
    if not lists or not stamp.exists() or not 0 <= time.time() - stamp.stat().st_mtime <= 48 * 3600:
        raise ValueError("no successful APT metadata refresh recorded within 48h; available updates unknown")
    result = command(["apt", "list", "--upgradable"], timeout=30)
    if result.returncode:
        raise ValueError("APT query failed; available updates unknown")
    count = sum("/" in line and "[upgradable from:" in line for line in result.stdout.splitlines())
    return check("package-updates", "maintenance", "warn" if count else "pass",
                 f"{count} upgradable packages in cached APT metadata; no changes applied",
                 [metric("updates", count, "count")], advisory=True)


def collect():
    for key, category, probe in [("failed-services", "host", services_probe),
                                  ("temperatures", "temperatures", temperature_probe),
                                  ("lan-sample", "network", network_probe),
                                  ("package-updates", "maintenance", updates_probe)]:
        try:
            yield probe()
        except (OSError, ValueError, TypeError, AttributeError, subprocess.TimeoutExpired) as error:
            yield check(key, category, "warn", str(error), observation="unknown")


if __name__ == "__main__":
    rank = 0
    for result in collect():
        severity = {"pass": 0, "warn": 1, "fail": 2}[result["status"]]
        rank = max(rank, severity)
        if os.environ.get("INFRA_CHECKS_FILE"):
            with open(os.environ["INFRA_CHECKS_FILE"], "a", encoding="utf-8") as sidecar:
                sidecar.write("@json\t" + json.dumps(result, allow_nan=False) + "\n")
        if severity or "--quiet" not in sys.argv:
            print(f"[{[' OK ', 'WARN', 'FAIL'][severity]}] {result['check']}: {result['detail']}")
    sys.exit(rank)
