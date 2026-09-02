#!/usr/bin/env bash
# load-drill.sh — the connection-budget drill, in one command.
#
# Runs a load scenario against an application while sampling the database
# underneath it, then turns both halves into a verdict with an exit code:
#
#   0  [ OK ]   the budget holds, with headroom
#   1  [FAIL]   a threshold broke — the app, or the budget, or both
#   2  [WARN]/  setup refused: a prerequisite is missing, or the drill would
#               have measured something other than what it claims to
#
# The refusals in the second category are the point. A load drill that measures
# the rate limiter, or runs against a Postgres tuned differently from
# production, produces a number that is worse than no number, because someone
# will trust it.
#
# Usage:
#   load-drill.sh steady          [options]   ramp until latency degrades
#   load-drill.sh deploy-overlap  [options]   steady load + a blue/green deploy
#   load-drill.sh up | down                   manage the isolated Postgres
#
# Options:
#   --base-url URL      application under test   (default http://127.0.0.1:5000)
#   --deploy-cmd CMD    command that performs the blue/green deploy
#                       (deploy-overlap only; run at --deploy-at seconds)
#   --deploy-at N       seconds into the run to fire it        (default 90)
#   --vus N             peak (steady) / constant (overlap) concurrency
#   --duration N        seconds, deploy-overlap only           (default 240)
#   --p95 N             latency threshold in ms
#   --inventory FILE    group_vars to cross-check max_connections against
#   --out DIR           artifacts directory  (default ./runs/<scenario>-<ts>)
#   --skip-checks       run even if the pre-flight refuses. You are on your own.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCENARIO=""
BASE_URL="http://127.0.0.1:5000"
DEPLOY_CMD=""
DEPLOY_AT=90
VUS=""
DURATION=240
P95=""
INVENTORY=""
OUTDIR=""
SKIP_CHECKS=0

ok()   { echo "[ OK ] $*"; }
warn() { echo "[WARN] $*" >&2; }
fail() { echo "[FAIL] $*" >&2; }
die()  { fail "$*"; exit 2; }

[ $# -gt 0 ] || { sed -n '7,30p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
SCENARIO="$1"; shift

while [ $# -gt 0 ]; do
    case "$1" in
        --base-url)    BASE_URL="$2"; shift 2 ;;
        --deploy-cmd)  DEPLOY_CMD="$2"; shift 2 ;;
        --deploy-at)   DEPLOY_AT="$2"; shift 2 ;;
        --vus)         VUS="$2"; shift 2 ;;
        --duration)    DURATION="$2"; shift 2 ;;
        --p95)         P95="$2"; shift 2 ;;
        --inventory)   INVENTORY="$2"; shift 2 ;;
        --out)         OUTDIR="$2"; shift 2 ;;
        --skip-checks) SKIP_CHECKS=1; shift ;;
        *) die "unknown option: $1" ;;
    esac
done

COMPOSE="docker compose -f $HERE/docker-compose.yml"

# ── up / down ─────────────────────────────────────────────────────────────────
case "$SCENARIO" in
    up)
        $COMPOSE up -d
        echo "Waiting for Postgres..."
        for _ in $(seq 1 60); do
            if $COMPOSE exec -T postgres pg_isready -q 2>/dev/null; then
                ok "Postgres up on port ${PGPORT:-55432}."
                echo "Restore a dump into it, point the app's connection strings at it, then:"
                echo "  ./load-drill.sh steady --base-url http://127.0.0.1:5000"
                exit 0
            fi
            sleep 1
        done
        die "Postgres did not become ready. \`$COMPOSE logs postgres\`"
        ;;
    down)
        # -v discards the volume: a drill database that survives between runs is
        # a drill that silently changes what it measures.
        $COMPOSE down -v
        ok "Drill environment removed (including its data volume)."
        exit 0
        ;;
    steady|deploy-overlap) ;;
    *) die "unknown scenario '$SCENARIO' (steady | deploy-overlap | up | down)" ;;
esac

# ── Pre-flight ────────────────────────────────────────────────────────────────
# Everything here exists because getting it wrong produces a confident number
# that is not about what you think it is about.
PREFLIGHT_FAILED=0
refuse() { fail "$*"; PREFLIGHT_FAILED=1; }

command -v k6   >/dev/null || refuse "k6 not found. https://k6.io/docs/get-started/installation/"
command -v psql >/dev/null || refuse "psql not found — install postgresql-client."
command -v jq   >/dev/null || refuse "jq not found — needed to build fixtures from the database."

: "${PGHOST:=127.0.0.1}"
: "${PGPORT:=55432}"
: "${PGUSER:=postgres}"
export PGHOST PGPORT PGUSER

CONFIG="$HERE/scenarios/endpoints.json"
[ -f "$CONFIG" ] || refuse "missing $CONFIG"

APP_DB=""
if [ -f "$CONFIG" ] && command -v jq >/dev/null; then
    APP_DB=$(jq -r '.pools.app.database // empty' "$CONFIG")
fi
: "${PGDATABASE:=${APP_DB:-postgres}}"
export PGDATABASE

if command -v psql >/dev/null; then
    if psql -Atqc 'SELECT 1' >/dev/null 2>&1; then
        ok "Postgres reachable at $PGUSER@$PGHOST:$PGPORT/$PGDATABASE"
    else
        refuse "cannot reach Postgres at $PGUSER@$PGHOST:$PGPORT/$PGDATABASE (PGPASSWORD set?)"
    fi
fi

MAXCONN=""
if psql -Atqc 'SELECT 1' >/dev/null 2>&1; then
    MAXCONN=$(psql -Atqc 'SHOW max_connections')
    RESERVED=$(psql -Atqc 'SHOW superuser_reserved_connections')

    # The drill's whole claim is "production's max_connections is enough". That
    # claim is void if the box under test carries a different number.
    if [ -n "$INVENTORY" ]; then
        [ -f "$INVENTORY" ] || refuse "inventory file not found: $INVENTORY"
        if [ -f "$INVENTORY" ]; then
            WANT=$(grep -E '^\s*postgres_max_connections:' "$INVENTORY" | head -1 | sed 's/.*:\s*//' | tr -d '"' | tr -d "'" | tr -d ' ')
            if [ -n "$WANT" ] && [ "$WANT" != "$MAXCONN" ]; then
                refuse "max_connections mismatch: this box has $MAXCONN, the inventory says $WANT. A drill on a different budget proves nothing about production."
            elif [ -n "$WANT" ]; then
                ok "max_connections = $MAXCONN, matching $(basename "$INVENTORY")"
            fi
        fi
    else
        warn "no --inventory given; max_connections ($MAXCONN) not cross-checked against production."
    fi
fi

# The application must be up and ready before load starts, or the ramp measures
# a cold start.
READY_PATH=$(jq -r '.health.ready // "/.well-known/ready"' "$CONFIG" 2>/dev/null || echo "/.well-known/ready")
if command -v curl >/dev/null; then
    if curl -fsS --max-time 5 "${BASE_URL%/}${READY_PATH}" >/dev/null 2>&1; then
        ok "Application ready at $BASE_URL"
    else
        refuse "application not ready at ${BASE_URL%/}${READY_PATH}"
    fi
else
    warn "curl not found; skipping the readiness check."
fi

if [ "$SCENARIO" = "deploy-overlap" ] && [ -z "$DEPLOY_CMD" ]; then
    refuse "deploy-overlap needs --deploy-cmd — the scenario IS the deploy. Without it this is just a flat load test."
fi

if [ "$PREFLIGHT_FAILED" = "1" ]; then
    if [ "$SKIP_CHECKS" = "1" ]; then
        warn "pre-flight refused, continuing because --skip-checks was given. Treat the result as indicative only."
    else
        die "pre-flight refused. Fix the above, or pass --skip-checks if you know why it is wrong."
    fi
fi

# ── Artifacts ─────────────────────────────────────────────────────────────────
TS=$(date -u '+%Y%m%dT%H%M%SZ')
OUTDIR="${OUTDIR:-$HERE/runs/${SCENARIO}-${TS}}"
mkdir -p "$OUTDIR"
CSV="$OUTDIR/pg-sample.csv"
SUMMARY="$OUTDIR/k6-summary.json"
FIXTURES="$HERE/scenarios/.fixtures.json"

echo "Artifacts: $OUTDIR"

# ── Fixtures ──────────────────────────────────────────────────────────────────
# Real traffic spreads across rows. A drill that reads one row measures the
# buffer cache and reports a throughput the application will never see.
echo '{}' > "$FIXTURES"
FIXTURE_NAMES=$(jq -r '.fixtures // {} | keys[]' "$CONFIG")
for name in $FIXTURE_NAMES; do
    QUERY=$(jq -r --arg n "$name" '.fixtures[$n].query' "$CONFIG")
    MINIMUM=$(jq -r --arg n "$name" '.fixtures[$n].minimum // 1' "$CONFIG")
    VALUES=$(psql -Atqc "$QUERY" || true)
    COUNT=$(printf '%s' "$VALUES" | grep -c . || true)

    if [ "${COUNT:-0}" -lt "$MINIMUM" ]; then
        MSG=$(jq -r --arg n "$name" '.fixtures[$n].onEmpty // "no rows"' "$CONFIG")
        if [ "$SKIP_CHECKS" = "1" ]; then
            warn "fixture '$name' has $COUNT rows (need $MINIMUM): $MSG"
        else
            die "fixture '$name' has $COUNT rows (need $MINIMUM). $MSG"
        fi
    fi

    jq --arg n "$name" --argjson v "$(printf '%s' "$VALUES" | jq -R -s 'split("\n") | map(select(length > 0))')" \
        '.[$n] = $v' "$FIXTURES" > "$FIXTURES.tmp" && mv "$FIXTURES.tmp" "$FIXTURES"
    ok "fixture '$name': $COUNT values"
done

# ── Sampler ───────────────────────────────────────────────────────────────────
"$HERE/pg-sample.sh" --out "$CSV" --interval 1 --label "$SCENARIO" 2> "$OUTDIR/pg-sample.log" &
SAMPLER_PID=$!
sleep 2
kill -0 "$SAMPLER_PID" 2>/dev/null || { cat "$OUTDIR/pg-sample.log" >&2; die "sampler died on startup"; }
ok "Sampling pg_stat_activity every 1s (pid $SAMPLER_PID)"

DEPLOY_PID=""
cleanup() {
    [ -n "$DEPLOY_PID" ] && kill "$DEPLOY_PID" 2>/dev/null || true
    kill -TERM "$SAMPLER_PID" 2>/dev/null || true
    wait "$SAMPLER_PID" 2>/dev/null || true
}
trap cleanup EXIT

# ── Deploy trigger ────────────────────────────────────────────────────────────
if [ "$SCENARIO" = "deploy-overlap" ]; then
    (
        sleep "$DEPLOY_AT"
        echo ">>> $(date -u '+%H:%M:%SZ') firing deploy: $DEPLOY_CMD" | tee -a "$OUTDIR/deploy.log"
        # Its failure must not kill the drill: a deploy that breaks under load
        # is itself a finding, and the sampler needs to keep recording.
        eval "$DEPLOY_CMD" >> "$OUTDIR/deploy.log" 2>&1 \
            && echo ">>> deploy finished ok" >> "$OUTDIR/deploy.log" \
            || echo ">>> deploy exited non-zero — see above" >> "$OUTDIR/deploy.log"
    ) &
    DEPLOY_PID=$!
    ok "Deploy scheduled at T+${DEPLOY_AT}s"
fi

# ── Load ──────────────────────────────────────────────────────────────────────
K6_EXIT=0
if [ "$SCENARIO" = "steady" ]; then
    VUS_PEAK="${VUS:-200}" P95_MS="${P95:-500}" \
    BASE_URL="$BASE_URL" SUMMARY_OUT="$SUMMARY" \
        k6 run "$HERE/scenarios/steady.js" 2>&1 | tee "$OUTDIR/k6.log" || K6_EXIT=$?
else
    VUS="${VUS:-50}" DURATION="$DURATION" P95_MS="${P95:-800}" \
    BASE_URL="$BASE_URL" SUMMARY_OUT="$SUMMARY" \
        k6 run "$HERE/scenarios/deploy-overlap.js" 2>&1 | tee "$OUTDIR/k6.log" || K6_EXIT=$?
fi

[ -n "$DEPLOY_PID" ] && wait "$DEPLOY_PID" 2>/dev/null || true
kill -TERM "$SAMPLER_PID" 2>/dev/null || true
wait "$SAMPLER_PID" 2>/dev/null || true
trap - EXIT

# ── Verdict ───────────────────────────────────────────────────────────────────
echo
echo "──────────────────────────────────────────────────────────────────────"
echo " Verdict"
echo "──────────────────────────────────────────────────────────────────────"

VERDICT=0

PEAK=$(awk -F',' '$4=="all" {if ($5+0 > m) m=$5+0} END {print m+0}' "$CSV")
USABLE=$(( ${MAXCONN:-128} - ${RESERVED:-3} ))
PER_INSTANCE=$(jq -r '[.pools | to_entries[] | select(.value.maxPoolSize) | .value.maxPoolSize] | add // 0' "$CONFIG")

echo "  peak client connections   $PEAK"
echo "  usable slots              $USABLE  (max_connections ${MAXCONN:-?} - ${RESERVED:-3} reserved)"

PCT=$(( PEAK * 100 / (USABLE > 0 ? USABLE : 1) ))
if   [ "$PCT" -ge 90 ]; then fail "peak used ${PCT}% of usable slots — no room for pg_dump, psql or an incident."; VERDICT=1
elif [ "$PCT" -ge 75 ]; then warn "peak used ${PCT}% of usable slots — thin. Budget the next application before adding one."
else ok "peak used ${PCT}% of usable slots."
fi

# The projection the steady scenario cannot observe directly: during a drain
# both slots of the deploying application are alive, each holding its own pools.
#
# The fleet is heterogeneous — deployments do not have the same pool sizes, and
# they do not deploy together — so the model is a per-deployment one:
#
#   steady = sum of every deployment's own per-instance total
#   worst  = steady + the largest single deployment's total
#
# The older `per-instance x instances x 2` said "every application drains at
# once", which is not a deploy anyone performs: deploy.yml loops one app at a
# time and deploy.sh blocks through the drain. That reading is still printed
# below, because an operator is entitled to ask what would happen if it did
# happen — it just does not decide the verdict.
STEADY=0
LARGEST=0
LARGEST_NAME=""
FLEET_DESC=""
FLEET_COUNT=0
while IFS="$(printf '\t')" read -r d_name d_total; do
    [ -n "${d_name:-}" ] || continue
    d_total=${d_total:-0}
    FLEET_COUNT=$(( FLEET_COUNT + 1 ))
    STEADY=$(( STEADY + d_total ))
    if [ -z "$FLEET_DESC" ]; then FLEET_DESC="$d_name $d_total"
    else FLEET_DESC="$FLEET_DESC + $d_name $d_total"
    fi
    if [ "$d_total" -gt "$LARGEST" ]; then LARGEST=$d_total; LARGEST_NAME=$d_name; fi
done < <(jq -r '
    .deployment.deployments // [] | .[]
    | [ (.name // "?"), ([.pools | to_entries[] | .value] | add // 0) ] | @tsv' "$CONFIG")

# Fallback for a config that has not been given a fleet: treat it as `instances`
# copies of the application under test, which is the old uniform model and the
# best guess available when nobody has written the fleet down.
if [ "$FLEET_COUNT" -eq 0 ] && [ "$PER_INSTANCE" -gt 0 ]; then
    INSTANCES=$(jq -r '.deployment.instances // 1' "$CONFIG")
    STEADY=$(( PER_INSTANCE * INSTANCES ))
    LARGEST=$PER_INSTANCE
    LARGEST_NAME="the application under test"
    FLEET_DESC="$INSTANCES x $PER_INSTANCE, assumed uniform — deployment.deployments is not set"
fi

if [ "$SCENARIO" = "steady" ] && [ "$STEADY" -gt 0 ]; then
    WORST=$(( STEADY + LARGEST ))
    echo "  fleet steady total        $STEADY  ($FLEET_DESC)"
    echo "  blue/green worst case     $WORST  ($STEADY steady + $LARGEST for the largest single drain: $LARGEST_NAME)"
    if [ "$WORST" -ge "$USABLE" ]; then
        fail "a deploy under load would exceed the usable slots ($WORST > $USABLE). Run 'deploy-overlap' to see it happen, and cut a pool or raise max_connections before production."
        VERDICT=1
    elif [ "$WORST" -ge $(( USABLE * 85 / 100 )) ]; then
        warn "a deploy under load reaches ${WORST}/${USABLE} slots. It fits, barely — one more application does not."
    else
        ok "a deploy under load fits: ${WORST}/${USABLE} slots."
    fi

    # The paranoid reading, reported and not enforced: every deployment drains
    # at the same time. It is what the per-role CONNECTION LIMITs have to add up
    # to, so it is worth a line even when the answer is comfortable.
    ALL_DRAIN=$(( STEADY * 2 ))
    if [ "$ALL_DRAIN" -ge "$USABLE" ]; then
        warn "if every deployment drained at once the fleet would want ${ALL_DRAIN}/${USABLE} slots. Serialising deploys is what keeps that hypothetical; per-application roles with a CONNECTION LIMIT are what enforce it."
    else
        ok "simultaneous drains also fit: ${ALL_DRAIN}/${USABLE} slots — the budget does not rest on deploys being serialised."
    fi
fi

# Pool ceiling: a database pinned at exactly its Maximum Pool Size, sustained,
# means requests were queueing for a connection. That is an application-side
# limit; raising max_connections does nothing for it.
while read -r key; do
    DB=$(jq -r --arg k "$key" '.pools[$k].database' "$CONFIG")
    CAP=$(jq -r --arg k "$key" '.pools[$k].maxPoolSize' "$CONFIG")
    [ "$DB" != "null" ] || continue
    HITS=$(awk -F',' -v db="$DB" -v cap="$CAP" '
        $3==db {n[$1] += $5}
        END {c=0; for (t in n) if (n[t] >= cap) c++; print c+0}' "$CSV")
    # Counted explicitly rather than with length(array), which is a gawk/mawk
    # extension the drill has no reason to depend on.
    SAMPLES=$(awk -F',' -v db="$DB" '$3==db && !seen[$1]++ {n++} END {print n+0}' "$CSV")
    if [ "${SAMPLES:-0}" -gt 0 ] && [ "$HITS" -gt $(( SAMPLES / 10 )) ] && [ "$HITS" -gt 3 ]; then
        warn "'$DB' sat at its pool ceiling ($CAP) for ${HITS}/${SAMPLES} samples — requests were queueing for a connection. Postgres was not the limit; the fix is a faster query or a larger pool, and pg_stat_statements says which."
    fi
done < <(jq -r '.pools | to_entries[] | select(.value.database) | .key' "$CONFIG")

if [ "$K6_EXIT" != "0" ]; then
    RL=$(jq -r '.metrics.drill_rate_limited.values.count // 0' "$SUMMARY" 2>/dev/null || echo 0)
    if [ "${RL%.*}" != "0" ]; then
        fail "requests were rate-limited (429) — the drill measured the limiter, not the database. The result is void. Check that the app trusts ${BASE_URL} as a proxy source for the client-IP header."
    else
        fail "load thresholds broke — see $OUTDIR/k6.log"
    fi
    VERDICT=1
else
    ok "load thresholds held."
fi

echo
if [ "$VERDICT" = "0" ]; then
    ok "Drill passed. Artifacts in $OUTDIR"
else
    fail "Drill failed. Artifacts in $OUTDIR"
fi
exit "$VERDICT"
