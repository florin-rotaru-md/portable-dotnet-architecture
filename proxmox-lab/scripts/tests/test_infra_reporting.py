"""Run with python3 -B -m unittest discover -s tests. No host tools are executed."""
import importlib.util
import json
from pathlib import Path
import subprocess
import unittest
from unittest.mock import patch


def load(name, file):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).resolve().parents[1] / file)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


reporting = load("reporting", "infra-report-payload.py")
probes = load("probes", "infra-host-metrics.py")


class InfraReportingTests(unittest.TestCase):
    def payload(self, output="", records="", script="cluster-health"):
        return reporting.payload("pve1", script, 0, "2026-09-12T12:00:00Z", output, records)

    def test_quiet_passes_have_evidence_without_cron_output(self):
        result = self.payload(records='quorum\tcluster\tpass\tobserved\tfalse\tquorate "yes"\n@complete\n')
        self.assertEqual([], result["lines"])
        self.assertEqual("pass", result["checks"][0]["status"])
        self.assertEqual(result, json.loads(json.dumps(result)))

    def test_partial_run_cannot_claim_success(self):
        result = self.payload(records="quorum\tcluster\tpass\tobserved\tfalse\tquorate\n")
        self.assertEqual("unknown", result["checks"][-1]["observation"])

    def test_late_failures_survive_bounded_lines_and_group_details(self):
        output = "\n".join(["[WARN] " + "x" * 600] * 210 + ["[FAIL] last disk failed"])
        records = "disks\tdisks\twarn\tobserved\tfalse\t" + "x" * 2000 + "\n"
        records += "disks\tdisks\tfail\tunknown\tfalse\tlast disk failed\n@complete\n"
        result = self.payload(output, records)
        self.assertEqual("[FAIL] last disk failed", result["lines"][0])
        self.assertEqual(200, len(result["lines"]))
        self.assertLessEqual(max(map(len, result["lines"])), 512)
        self.assertTrue(result["checks"][0]["detail"].startswith("last disk failed"))
        self.assertEqual("unknown", result["checks"][0]["observation"])

    def test_copy_job_reports_execution_without_claiming_archive_coverage(self):
        result = self.payload(script="r2-backup")
        self.assertEqual("monitoring", result["checks"][0]["category"])
        self.assertIn("backup-verify", result["checks"][0]["detail"])

    def test_metrics_keep_numeric_values_and_hardware_limits(self):
        observed = probes.temperatures({"coretemp": {"Package": {"temp1_input": 72, "temp1_max": 80, "temp1_crit": 100}}})
        result = self.payload(records="@json\t" + json.dumps(observed) + "\n@complete\n")
        metric = result["checks"][0]["metrics"][0]
        self.assertEqual(72, metric["value"])
        self.assertEqual(100, metric["failureAbove"])

    def test_empty_sensors_or_missing_limits_are_unknown(self):
        for document in ({}, {"chip": {"cpu": {"temp1_input": 42}}}):
            result = probes.temperatures(document)
            self.assertEqual("unknown", result["observation"])
            self.assertEqual("warn", result["status"])

    def test_critical_temperature_wins_over_missing_other_limits(self):
        result = probes.temperatures({"chip": {"cpu": {"temp1_input": 110, "temp1_crit": 100},
                                               "other": {"temp2_input": 42}}})
        self.assertEqual("fail", result["status"])
        self.assertEqual("unknown", result["observation"])

    def test_partial_ping_loss_keeps_rtt_and_packet_count(self):
        output = "20 packets transmitted, 19 received, 5% packet loss, time 10ms\nrtt min/avg/max/mdev = 0.1/0.42/0.9/0.1 ms"
        result = probes.ping_result(output, 0, "192.168.0.12")
        self.assertEqual("warn", result["status"])
        values = {metric["key"]: metric["value"] for metric in result["metrics"]}
        self.assertEqual({"packet-loss": 5, "latency": .42, "ping-count": 20}, values)

    def test_total_ping_loss_fails_without_inventing_latency(self):
        result = probes.ping_result("20 packets transmitted, 0 received, 100% packet loss", 1, "peer")
        self.assertEqual("fail", result["status"])
        self.assertNotIn("latency", [metric["key"] for metric in result["metrics"]])

    def test_ping_command_error_or_unparseable_reply_is_unknown(self):
        for output, code in [("ping: permission denied", 2), ("unexpected output", 0)]:
            with self.assertRaises(ValueError):
                probes.ping_result(output, code, "peer")

    def test_failed_queries_cannot_report_zero_failed_services_or_normal_temperatures(self):
        with patch.object(probes, "command", return_value=subprocess.CompletedProcess([], 1, "", "failure")):
            results = list(probes.collect())
        self.assertTrue(all(result["observation"] == "unknown" for result in results))
        self.assertTrue(all(not result["metrics"] for result in results))


if __name__ == "__main__":
    unittest.main()
