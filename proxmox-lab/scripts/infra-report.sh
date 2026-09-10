#!/usr/bin/env bash
# infra-report — runs a helper script unchanged, then POSTs its outcome to the
# app's infra monitor (platform ADR-0015, POST /api/infra/reports).
#
#   infra-report cluster-health --quiet
#
# The exit code passes straight through untouched. The OUTPUT does not, and the
# difference matters before you wrap anything else: stderr is merged into stdout
# below and re-printed there, so a cron line that redirects stdout — as the
# pve-config-backup and r2-backup entries do, `… >/dev/null` — now discards the
# stderr cron used to mail. That is deliberate for those two, whose failure story
# travels in the POST instead, and costs nothing today because root mail is
# generated, rejected by the recipient's provider on a Spamhaus block and dropped
# (15.3). The app values the arrival as much as the content: a report landing daily
# is the proof the cron layer itself is alive, the one failure root mail cannot see.
#
# Config: /etc/infra-report.conf (root:root 600), two lines:
#   INFRA_URL="https://<api-origin>/api/infra/reports"
#   INFRA_TOKEN="<InfraMonitor:IngestToken>"
# No config file = run the script normally and skip the report, so a node
# without the app configured behaves exactly as before this wrapper existed.
#
# THAT PASS-THROUGH IS ALSO THE HAZARD, and it is why CONF above is never changed
# on a node before the new file exists there. A node that does not have the path
# this script reads gets the no-config branch — the wrapped script runs, prints
# the same bytes, exits with the same code, cron does with them whatever the
# entry's redirect says, and the reports simply stop. Nothing on the host says
# so, and the first symptom is the app's own freshness check warning "silent
# for …" up to 26 hours later, pointing at a dead cron rather than at this file.
# A rename cost four days of blind ingest exactly this way (2026-09-04): write
# the new file, verify a report lands, and only then remove the old one —
# platform docs/waa/infra/OPERATIONS.md §1.6.
#
# THE MIRROR OF THAT HAZARD IS WORSE, because the app's own backstop cannot catch it. A
# missing config file stops reports, and the freshness check eventually says "silent for …".
# A wrapped script that exits 0 having printed nothing produces a report that ARRIVES:
# InfraCheckService.EvaluateIngest sees exit 0 with no [FAIL]/[WARN] line, scores it pass and
# stores Detail = "exit 0, no output". Freshness is satisfied, so nothing warns, ever. Under
# --quiet that empty shape is also exactly what a genuinely clean run looks like — nothing
# here can tell "checked everything, all clean" from "checked nothing". backup-verify's USB
# block used to take a bare exit 0 on a node without the drive, assuming the peer covered it;
# on 2026-09-10 neither node had one, so both posted a green empty report every morning while
# no vzdump had EVER run (see the comment on that block). Hence the rule for every script
# wrapped here: a check may opt out, but it must SAY so on stdout — an early silent exit makes
# this wrapper report a lie nothing downstream can detect.

set -uo pipefail
CONF=/etc/infra-report.conf

script="${1:?usage: infra-report <script> [args…]}"
shift

out="$("/usr/local/sbin/$script" "$@" 2>&1)"
exit_code=$?

# What the script printed, stdout and stderr together, on stdout (mailed by cron
# only where the entry does not redirect it — see the header).
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
