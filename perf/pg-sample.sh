#!/usr/bin/env bash
# pg-sample.sh — answers one question: how many connections were actually open,
# to which database, in what state, second by second.
#
# This is the half of a load drill that the HTTP client cannot see. Latency
# tells you something got slow; this tells you whether the app was queueing for
# a connection (count pinned flat at Maximum Pool Size, Postgres mostly idle) or
# Postgres was the one struggling (active climbing, waits appearing). The two
# look identical from outside and have opposite fixes, which is why one is
# useless without the other.
#
# Runs until stopped (SIGINT/SIGTERM), writing tidy CSV — one row per
# database/state per sample — plus a peak line to stderr on exit.
#
# Usage: pg-sample.sh --out FILE [--interval SECONDS] [--label TEXT]
#   Connection comes from the standard PG* environment variables
#   (PGHOST/PGPORT/PGUSER/PGPASSWORD/PGDATABASE), so it works unchanged against
#   the drill container, a cloned VM, or production read-only.

set -euo pipefail

OUT=""
INTERVAL=1
LABEL=""

while [ $# -gt 0 ]; do
    case "$1" in
        --out)      OUT="$2"; shift 2 ;;
        --interval) INTERVAL="$2"; shift 2 ;;
        --label)    LABEL="$2"; shift 2 ;;
        *) echo "usage: pg-sample.sh --out FILE [--interval SECONDS] [--label TEXT]" >&2; exit 2 ;;
    esac
done

[ -n "$OUT" ] || { echo "FAIL: --out is required" >&2; exit 2; }
command -v psql >/dev/null || { echo "FAIL: psql not found — install postgresql-client" >&2; exit 2; }

: "${PGHOST:=127.0.0.1}"
: "${PGPORT:=5432}"
: "${PGUSER:=postgres}"
: "${PGDATABASE:=postgres}"
export PGHOST PGPORT PGUSER PGDATABASE

# Fail fast and loudly: a sampler that silently produced an empty file would let
# a drill report "peak 0 connections — plenty of headroom".
psql -Atqc 'SELECT 1' >/dev/null 2>&1 || {
    echo "FAIL: cannot reach Postgres at $PGUSER@$PGHOST:$PGPORT/$PGDATABASE" >&2
    exit 2
}

MAXCONN=$(psql -Atqc 'SHOW max_connections')
RESERVED=$(psql -Atqc 'SHOW superuser_reserved_connections')
echo "max_connections=$MAXCONN superuser_reserved=$RESERVED" >&2

printf 'ts,label,datname,state,count\n' > "$OUT"

PEAK=0
PEAK_TS=""

finish() {
    # The peak is the number the whole drill is about, so it goes to stderr
    # where a human sees it even if nobody opens the CSV.
    echo "peak_total=$PEAK peak_at=${PEAK_TS:-n/a} max_connections=$MAXCONN" >&2
    exit 0
}
trap finish INT TERM

while true; do
    TS=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

    # 'client backend' only: autovacuum workers, the checkpointer and the
    # walsender are not application connections, and counting them would inflate
    # the number the pool budget is compared against. (Since PG 12 walsenders
    # come out of max_wal_senders, not max_connections, so they are doubly wrong
    # to include here.)
    SNAPSHOT=$(psql -Atq -F',' -c "
        SELECT coalesce(datname, '-'), state, count(*)
        FROM pg_stat_activity
        WHERE backend_type = 'client backend'
          -- not the sampler's own session: the verdict compares this count with the
          -- application's pool cap, and a count that includes the observer is off
          -- by one in exactly the direction that makes a cap look exceeded.
          AND pid <> pg_backend_pid()
        GROUP BY 1, 2
        ORDER BY 1, 2;") || { echo "WARN: sample failed at $TS (server refusing connections?)" >&2; sleep "$INTERVAL"; continue; }

    TOTAL=0
    while IFS=',' read -r datname state count; do
        [ -n "${datname:-}" ] || continue
        printf '%s,%s,%s,%s,%s\n' "$TS" "$LABEL" "$datname" "${state:-unknown}" "$count" >> "$OUT"
        TOTAL=$((TOTAL + count))
    done <<< "$SNAPSHOT"

    printf '%s,%s,%s,%s,%s\n' "$TS" "$LABEL" '*total*' 'all' "$TOTAL" >> "$OUT"

    if [ "$TOTAL" -gt "$PEAK" ]; then
        PEAK=$TOTAL
        PEAK_TS=$TS
    fi

    sleep "$INTERVAL"
done
