#!/usr/bin/env bash
# infra-report — runs a helper script unchanged, then POSTs its outcome to the
# app's infra monitor (platform ADR-0015, POST /api/infra/reports).
#
#   infra-report cluster-health --quiet
#
# The wrapped script's output and exit code pass straight through, so cron's
# MAILTO behaviour is exactly what it was — this only adds the report. The app
# values the arrival as much as the content: a report landing daily is the
# proof the cron layer itself is alive, the one failure root mail cannot see.
#
# Config: /etc/infra-report.conf (root:root 600), two lines:
#   INFRA_URL="https://<api-origin>/api/infra/reports"
#   INFRA_TOKEN="<InfraMonitor:IngestToken>"
# No config file = run the script normally and skip the report, so a node
# without the app configured behaves exactly as before this wrapper existed.
#
# THAT PASS-THROUGH IS ALSO THE HAZARD, and it is why this path is never changed
# on a node before the new file exists. The file was /etc/waa-infra-report.conf
# until the estate dropped the product prefix; a node still holding only the old
# name gets the no-config branch — the wrapped script runs, prints the same
# output, exits with the same code, cron mails the same bytes, and the reports
# simply stop. Nothing on the host says so, and the first symptom is the app's
# own freshness check warning "silent for …" up to 26 hours later, pointing at a
# dead cron rather than at a renamed file. Write the new file, verify a report
# lands, and only then remove the old one — platform docs/waa/infra/OPERATIONS.md §1.6.

set -uo pipefail
CONF=/etc/infra-report.conf

script="${1:?usage: infra-report <script> [args…]}"
shift

out="$("/usr/local/sbin/$script" "$@" 2>&1)"
exit_code=$?

# Unchanged cron contract: print what the script printed (mailed when non-empty).
[ -n "$out" ] && printf '%s\n' "$out"

if [ -r "$CONF" ]; then
    # shellcheck source=/dev/null
    . "$CONF"
    if [ -n "${INFRA_URL:-}" ] && [ -n "${INFRA_TOKEN:-}" ]; then
        # python3 ships on PVE hosts; it builds the JSON so no line can break quoting.
        payload="$(printf '%s' "$out" | python3 -c '
import json, sys
lines = [l for l in sys.stdin.read().splitlines() if l.strip()][:200]
print(json.dumps({
    "host": sys.argv[1],
    "script": sys.argv[2],
    "exitCode": int(sys.argv[3]),
    "lines": lines,
}))' "$(hostname)" "$script" "$exit_code")"

        curl -fsS -m 20 -X POST \
            -H "Authorization: Bearer $INFRA_TOKEN" \
            -H "Content-Type: application/json" \
            -d "$payload" "$INFRA_URL" >/dev/null 2>&1 ||
            logger -t infra-report "POST to $INFRA_URL failed for $script (exit $exit_code stays authoritative)"
    fi
fi

exit "$exit_code"
