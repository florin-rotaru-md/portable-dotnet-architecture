#!/usr/bin/env bash
# node-return.sh — the 14.2 procedure ("returning a node after a long outage"),
# with the ordering enforced by code instead of by memory.
#
# The order matters: rejoin → align versions → replicate → only then migrate.
# The classic mistake is migrating workload onto a node that is behind on
# packages or whose replica is stale — this script refuses to reach the
# migration step until the earlier gates pass.
#
# Run ON THE RETURNING NODE, after powering it on. Interactive — it asks before
# every action that changes anything. Safe to re-run at any point (all gates
# are re-checked from scratch), including after the reboot it may ask for.
#
# Usage: node-return [--check]
#   --check   report the state of every gate and exit — change nothing

set -uo pipefail

CHECK=0
[ "${1:-}" = "--check" ] && CHECK=1

HOST=$(hostname)
say()     { printf '\n== %s\n' "$1"; }
ok()      { printf '[ OK ] %s\n' "$1"; }
bad()     { printf '[STOP] %s\n' "$1"; }
confirm() {
    [ "$CHECK" = 1 ] && return 1
    read -r -p "$1 [y/N] " a </dev/tty; [ "$a" = "y" ] || [ "$a" = "Y" ]
}

PEER_ADDR=$(awk -v me="$HOST" '
    /node {/ {name=""; addr=""}
    $1 == "name:" {name=$2}
    $1 == "ring0_addr:" {addr=$2}
    /}/ { if (name != "" && name != me && addr != "") print addr }' /etc/pve/corosync.conf | head -1)
PEER_NAME=$(awk -v me="$HOST" '
    /node {/ {name=""}
    $1 == "name:" {if ($2 != me) name=$2}
    /}/ { if (name != "") {print name; exit} }' /etc/pve/corosync.conf)
peer() { ssh -o BatchMode=yes -o ConnectTimeout=5 "root@$PEER_ADDR" "$@"; }

if [ -z "$PEER_ADDR" ] || ! peer true 2>/dev/null; then
    bad "can't reach the peer node over SSH ($PEER_NAME @ ${PEER_ADDR:-unknown}). Nothing here is safe without it."
    exit 2
fi

# ── Gate 1: cluster membership, links, clock, pools ──────────────────────────
say "Gate 1 — the node is back as a healthy member (14.2 step 1)"
FAILED=0
pvecm status 2>/dev/null | grep -q 'Quorate:.*Yes' \
    && ok "quorate" || { bad "not quorate — wait for corosync, check both links"; FAILED=1; }
corosync-cfgtool -s 2>/dev/null | grep -qiE 'faulty|disconnected' \
    && { bad "a corosync link is down — fix cabling first (corosync-cfgtool -s)"; FAILED=1; } || ok "both rings healthy"
[ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null)" = "yes" ] \
    && ok "clock synchronized" || { bad "clock not synchronized yet — give chrony a minute, re-run"; FAILED=1; }
[ "$(zpool status -x 2>&1)" = "all pools are healthy" ] \
    && ok "pools imported and healthy" || { bad "pool problem — zpool status before anything else"; FAILED=1; }
[ "$FAILED" = 1 ] && { bad "Gate 1 failed — nothing below is safe yet."; exit 2; }

# ── Gate 2: package versions aligned with the peer (14.2 step 2) ─────────────
say "Gate 2 — version alignment (the one that bites)"
LOCAL_VER=$(pveversion); PEER_VER=$(peer pveversion)
if [ "$LOCAL_VER" = "$PEER_VER" ]; then
    ok "both nodes on $LOCAL_VER"
else
    bad "version skew: this node $LOCAL_VER, peer $PEER_VER"
    echo "       Live migration from the peer's newer QEMU onto this older one can fail."
    if confirm "Run 'apt update && apt dist-upgrade' on this node now?"; then
        apt update && apt dist-upgrade -y
        if [ -f /var/run/reboot-required ]; then
            bad "a new kernel landed — reboot this node, then re-run node-return."
            exit 2
        fi
        [ "$(pveversion)" = "$PEER_VER" ] || { bad "still skewed after upgrade — compare 'pveversion -v' on both nodes by hand."; exit 2; }
        ok "aligned: $(pveversion)"
    else
        exit 2
    fi
fi

# ── Gate 3: replication caught up (14.2 step 3) ──────────────────────────────
say "Gate 3 — replication catch-up (the jobs run on the peer; this is the big transfer)"
JOB_IDS=$(peer pvesr status 2>/dev/null | awk 'NR > 1 {print $1}')
if [ -z "$JOB_IDS" ]; then
    ok "no replication jobs on the peer (nothing to catch up)"
else
    for id in $JOB_IDS; do
        if [ "$CHECK" = 0 ]; then
            echo "       forcing job $id instead of waiting out the retry backoff..."
            peer pvesr run --id "$id" 2>/dev/null || true
        fi
    done
    while :; do
        # Columns: JobID Enabled Target LastSync NextSync Duration FailCount State
        BAD=$(peer pvesr status 2>/dev/null | awk 'NR > 1 && ($7 + 0 > 0 || $8 != "OK") {print $1}')
        [ -z "$BAD" ] && { ok "all replication jobs OK"; break; }
        [ "$CHECK" = 1 ] && { bad "jobs not caught up yet: $(echo "$BAD" | tr '\n' ' ')"; break; }
        echo "       still syncing: $(echo "$BAD" | tr '\n' ' ')— checking again in 30s (Ctrl+C is safe; re-run later)"
        sleep 30
    done
    echo "       peer pool usage (watch the old pinned snapshot release its space):"
    peer zpool list 2>/dev/null | sed 's/^/       /'
fi
echo "       Reminder: do NOT 'qm start' anything on this node — its local disks are stale until replication is current (14.2)."

[ "$CHECK" = 1 ] && { say "--check done — no changes made."; exit 0; }

# ── Step 4: move workload back, live (14.2 step 5) ───────────────────────────
say "Migrate workload back (only now is it safe)"
RUNNING=$(peer qm list 2>/dev/null | awk '$3 == "running" {print $1}')
if [ -z "$RUNNING" ]; then
    ok "no running VMs on the peer"
else
    for vm in $RUNNING; do
        NAME=$(peer qm config "$vm" 2>/dev/null | awk -F': ' '/^name:/ {print $2}')
        if confirm "Live-migrate $vm ($NAME) back to $HOST?"; then
            peer qm migrate "$vm" "$HOST" --online && ok "$vm migrated" || bad "$vm migration failed — see the task log on the peer"
        fi
    done
fi

# ── Step 5: scrub after the idle period (14.2 step 6) ────────────────────────
say "Scrub"
if confirm "The pools sat idle — start 'zpool scrub apps && zpool scrub db' now (runs in background)?"; then
    zpool scrub apps 2>/dev/null || true
    zpool scrub db   2>/dev/null || true
    ok "scrubs started — progress: zpool status"
fi

say "Done. Finish with a full sweep: cluster-health"
