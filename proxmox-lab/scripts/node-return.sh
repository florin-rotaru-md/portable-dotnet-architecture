#!/usr/bin/env bash
# node-return.sh — the 16.2 procedure ("returning a node after a long outage"),
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
# READ THIS BEFORE AN OUTAGE, NOT DURING ONE: everything below describes the repo copy.
# What `node-return` runs from /usr/local/sbin on both nodes is still the 2026-09-04 build
# (verified 2026-09-10, identical 6306 bytes on each), and it fails in the two places this
# procedure can least afford — it probes the peer with a plain `ssh root@<ring0_addr>`,
# which on pve2 answers "Host key verification failed" and aborts before Gate 1, and its
# link check is one grep for `disconnected` over the whole of corosync-cfgtool, so the 10G
# cable being unplugged by design (5.2) hard-exits Gate 1 on every run, --check included.
# Re-run portable-dotnet-architecture/proxmox-lab/BUILD.md#hardware-and-firmware on the node BEFORE you need this, not while a node is down.
#
# Usage: node-return [--check]
#   --check   report the state of every gate and exit — change nothing

set -uo pipefail

CHECK=0
[ "${1:-}" = "--check" ] && CHECK=1

# Corosync links that are plugged in on purpose and pulled out again afterwards, so
# "disconnected" is their resting state rather than an incident. Link 1 is the 10G
# direct cable (5.2): it exists to make a migration fast, not to carry membership.
# Link 0 — the LAN ring — is the one that must never be down, and it is deliberately
# NOT in this list. Keep this in step with ON_DEMAND_LINKS in cluster-health.sh: two
# scripts disagreeing about which link is allowed to be down is how one of them ends
# up trusted and the other ignored.
ON_DEMAND_LINKS="1"

HOST=$(hostname)
say()     { printf '\n== %s\n' "$1"; }
ok()      { printf '[ OK ] %s\n' "$1"; }
bad()     { printf '[STOP] %s\n' "$1"; }
confirm() {
    [ "$CHECK" = 1 ] && return 1
    read -r -p "$1 [y/N] " a </dev/tty; [ "$a" = "y" ] || [ "$a" = "Y" ]
}

# The newest kernel dpkg has actually installed. Status must be 'ii': a bare
# 'dpkg-query -W' glob also returns 'un' and 'rc' leftovers (pve2 lists
# proxmox-kernel-7.0.14-15-pve as 'un' next to the -signed one it really has), and
# neither has a kernel behind it — comparing against one produces a STOP that no
# reboot can clear. Both name flavours are matched; only one is ever installed.
newest_installed_kernel() {
    dpkg-query -W -f '${db:Status-Abbrev} ${Package}\n' \
        'proxmox-kernel-*-pve-signed' 'proxmox-kernel-*-pve' 2>/dev/null |
        awk '$1 == "ii" { sub(/^proxmox-kernel-/, "", $2); sub(/-signed$/, "", $2); print $2 }' |
        sort -V | tail -1
}
# /var/run/reboot-required is a Debian *desktop* convention, written by
# update-notifier-common or needrestart. A Proxmox host has neither, and no hook in
# /etc/kernel/postinst.d writes it — verified on both nodes 2026-09-10 while both
# carried an unbooted 7.0.14-15-pve (pve1 running -12, pve2 running -8). Testing for
# that file was therefore never once true here, so the gate it guarded never fired,
# and the very state it exists to catch was live on both nodes unreported. Ask the
# kernel packages instead, and only when one is strictly newer: a node deliberately
# booted back onto an older kernel to ride out a regression is not pending a reboot,
# and telling it to reboot forwards into the kernel it just escaped is worse than
# saying nothing. The cost of missing this is not a failed migration — it is taking
# the whole workload back onto a node you are about to reboot, and running this
# entire procedure a second time.
reboot_pending() {
    NEWEST=$(newest_installed_kernel)
    [ -n "$NEWEST" ] && [ "$NEWEST" != "$(uname -r)" ] &&
        [ "$(printf '%s\n%s\n' "$NEWEST" "$(uname -r)" | sort -V | tail -1)" = "$NEWEST" ]
}

# The peer is addressed by whichever of its ring addresses answers SSH, ring 0 first —
# not by a hardcoded ring0_addr. Take the addresses from the file and never from a link
# number written in the guide: the numbering is per-cluster and invisible from the network
# (`pvecm` gives ring 0 to whatever address the cluster was created on), so the number in
# any given section is the build that was intended, not necessarily the one you have. On
# this cluster ring 0 is the routable LAN (192.168.0.11/.12 over vmbr0) and ring 1 is the
# direct 10G cable:  grep ring._addr /etc/pve/corosync.conf
# Walking every ring address instead of pinning ring 0 is what keeps this script runnable
# on the day it is needed most. 5.2 makes the 10G cable's resting state "unplugged", so a
# cluster numbered the other way round — or one rejoined with its links crossed, which the
# join API accepts without complaint (portable-dotnet-architecture/proxmox-lab/RECOVERY.md#vm-or-node-loss 6) — carries its peer address
# on a cable that is out, and this script's very first act, the SSH below, would fail. It
# would abort at the peer check on the exact machine it exists to bring back. Ring 1 also
# covers the inverse: the day ring 0 is the one that is down.
PEER_NAME=$(awk -v me="$HOST" '
    /node {/ {name=""}
    $1 == "name:" {if ($2 != me) name=$2}
    /}/ { if (name != "") {print name; exit} }' /etc/pve/corosync.conf)
PEER_ADDRS=$(awk -v me="$HOST" '
    /node {/ {name=""; addrs=""}
    $1 == "name:" {name=$2}
    $1 ~ /^ring[0-9]+_addr:$/ {addrs = addrs $2 " "}
    /}/ { if (name != "" && name != me && addrs != "") print addrs }' /etc/pve/corosync.conf | head -1)

# Candidates come from the PEER's stanza only. Sweeping every ring_addr in the file would
# put this node's own second address in the list, and an ssh to self passes every gate
# below vacuously — same version, same pvesr status, a "migration" onto the host it
# started from. An unreachable peer must stop the script; a peer that is secretly this
# node must never look like a reachable one.
#
# The host key is resolved the way PVE itself does, not the way a human does. Every gate
# below runs through peer(), so getting this wrong does not degrade the script — it aborts
# the whole 16.2 procedure at the first line, on the node least able to afford it. A plain
# `ssh root@<addr>` leans on /root/.ssh and /etc/ssh, which are per-node and unmanaged:
# pve2 has neither an entry for pve1 nor the legacy /etc/ssh/ssh_known_hosts symlink that
# pve1 happens to carry, so from pve2 that call answers "Host key verification failed",
# exit 255 (reproduced 2026-09-10) — and pve2 is the node this procedure runs on most,
# being the laptop failover node that goes away and comes back (portable-dotnet-architecture/proxmox-lab/BUILD.md#laptop-power; the
# README gives it "role: failover"). The old message blamed the network ("can't reach the
# peer node"), sending the operator to cabling and switches while the cluster was quorate
# and PVE's own migration worked fine. The probe is `ssh true` and not ping for the same
# reason: pve2 pings 192.168.0.11 happily.
#
# PVE::SSHInfo::ssh_info_to_ssh_opts uses /etc/pve/nodes/<node>/ssh_known_hosts with
# HostKeyAlias=<node>. pmxcfs distributes that file, so both nodes always hold both keys
# and this works in either direction — the same mechanism cluster-health.sh now uses. Do
# NOT reach for /etc/pve/priv/known_hosts instead: it is the legacy merged store, it
# carries a pve1 entry and no pve2 entry on this cluster (so it would break the
# pve1-is-returning case that works today), and `pvecm updatecerts --unmerge-known-hosts`
# exists to take it apart. HostKeyAlias is also what makes the address walk above safe at
# all: that file keys the peer under its NODE NAME alone, so without the alias every
# address in it would fail verification. The -f test mirrors SSHInfo's own, for a node
# whose file has not been generated yet.
PEER_KH="/etc/pve/nodes/$PEER_NAME/ssh_known_hosts"
KH_OPTS=""
[ -n "$PEER_NAME" ] && [ -f "$PEER_KH" ] && KH_OPTS="-o UserKnownHostsFile=$PEER_KH -o GlobalKnownHostsFile=none"
peer_try() {
    addr=$1; shift
    # shellcheck disable=SC2086  # KH_OPTS is a deliberate word-split option pair
    ssh -o BatchMode=yes -o ConnectTimeout=5 -o HostKeyAlias="$PEER_NAME" \
        $KH_OPTS "root@$addr" "$@"
}

PEER_ADDR=""
for a in $PEER_ADDRS; do
    peer_try "$a" true 2>/dev/null && { PEER_ADDR=$a; break; }
done
peer() { peer_try "$PEER_ADDR" "$@"; }

if [ -z "$PEER_ADDR" ]; then
    bad "the peer node ($PEER_NAME @ ${PEER_ADDRS:-unknown}) did not answer SSH on any ring address. Nothing here is safe without it."
    echo "       Expected only if it is genuinely down. If it is up, this is host-key trust, not"
    echo "       reachability: /etc/pve/nodes/$PEER_NAME/ssh_known_hosts — the per-node file PVE"
    echo "       keeps, not /root/.ssh — is missing or stale. 'pvecm updatecerts' on BOTH nodes"
    echo "       regenerates that file; re-run afterwards. 21.7 inventories the four host-key pins"
    echo "       and says updatecerts is NOT the repair for a hand-typed 'ssh pve1' — that is"
    echo "       /root/.ssh/known_hosts, a different file, which this script never reads."
    exit 2
fi

# ── Gate 1: cluster membership, links, clock, pools, pending kernel ──────────
say "Gate 1 — the node is back as a healthy member (16.2 step 1)"
FAILED=0
pvecm status 2>/dev/null | grep -q 'Quorate:.*Yes' \
    && ok "quorate" || { bad "not quorate — wait for corosync, then look at ring 0 (the LAN) and the QDevice at 192.168.0.10; link 1 is expected to be down (5.2)"; FAILED=1; }
# Judged per link, not with one grep over the whole output, because the two links do
# not mean the same thing — and the old one-liner got both halves wrong. Link 1 is the
# on-demand 10G cable (5.2), disconnected almost all of the time by design, so the grep
# matched on the cluster's resting state and Gate 1 hard-exited 2 on every run: the 16.2
# procedure was unrunnable, --check included, and the message sent the operator off to
# "fix cabling" for a link 5.2 explicitly says not to fix. The other half is the mirror
# image: `|| ok` fired whenever the grep matched nothing, and an empty result set is not
# an observation. corosync-cfgtool failing — normal for the first minute on a node that
# has just powered on, which is exactly when this script runs — printed a green ring line
# during the failure the check exists to report. Same parser as cluster-health.sh.
LINK_STATES=$(corosync-cfgtool -s 2>/dev/null | awk '
    /^LINK ID/  { if (id != "") print id, (down ? "down" : "up"); id = $3; down = 0; next }
    /disconnected|FAULTY|faulty/ { down = 1 }
    END         { if (id != "") print id, (down ? "down" : "up") }')
DOWN_REQUIRED=""; DOWN_ONDEMAND=""
while read -r lid lstate; do
    [ -n "$lid" ] || continue
    [ "$lstate" = "down" ] || continue
    case " $ON_DEMAND_LINKS " in
        *" $lid "*) DOWN_ONDEMAND="$DOWN_ONDEMAND $lid" ;;
        *)          DOWN_REQUIRED="$DOWN_REQUIRED $lid" ;;
    esac
done <<EOF
$LINK_STATES
EOF
if [ -z "$LINK_STATES" ]; then
    bad "corosync-cfgtool reported no links — this check DID NOT RUN, so the rings are unknown, not healthy."
    echo "       On a node that has just powered on, corosync usually needs a minute: systemctl status corosync, then re-run."
    FAILED=1
elif [ -n "$DOWN_REQUIRED" ]; then
    bad "corosync link(s)$DOWN_REQUIRED down — these carry cluster membership, not just throughput."
    echo "       Check 'ip link' on both ends before the cable: pve1's X550 stays visible and reports"
    echo "       'Link detected: no', while pve2's Thunderbolt dock vanishes from 'ip link' entirely,"
    echo "       address and all (5.2). Migrating onto a node whose membership ring is down puts the"
    echo "       workload one dropped packet away from a fence."
    FAILED=1
elif [ -n "$DOWN_ONDEMAND" ]; then
    ok "membership ring healthy; on-demand link(s)$DOWN_ONDEMAND unplugged as expected (5.2)"
else
    ok "all corosync links healthy"
fi
[ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null)" = "yes" ] \
    && ok "clock synchronized" || { bad "clock not synchronized yet — give chrony a minute, re-run"; FAILED=1; }
[ "$(zpool status -x 2>&1)" = "all pools are healthy" ] \
    && ok "pools imported and healthy" || { bad "pool problem — zpool status before anything else"; FAILED=1; }
# Asked here, in Gate 1, and not only on the path where this script ran the upgrade
# itself: a node that has just been rebooted onto the wrong kernel arrives in exactly
# that state, and `node-return --check` has to be able to say so before anyone moves a
# VM. Both nodes were carrying an unbooted 7.0.14-15-pve on 2026-09-10 and nothing said a
# word (see reboot_pending above).
reboot_pending \
    && { bad "running $(uname -r) but $(newest_installed_kernel) is installed — reboot this node, then re-run node-return."; FAILED=1; } \
    || ok "running the newest installed kernel ($(uname -r))"
[ "$FAILED" = 1 ] && { bad "Gate 1 failed — nothing below is safe yet."; exit 2; }

# ── Gate 2: package versions aligned with the peer (16.2 step 2) ─────────────
say "Gate 2 — version alignment (the one that bites)"
# `pveversion` without -v is a single line ending in "(running kernel: X)", so comparing
# that string compares RUNNING KERNELS, not packages — and in a two-node lab the running
# kernels differ by design: each node reboots on its own schedule, and 16.2 exists
# precisely because this one has been down. Verified 2026-09-10: both nodes carried an
# identical package set (pve-manager 9.2.11 byte-for-byte), pve1 running 7.0.14-12-pve and
# pve2 7.0.14-8-pve, with 7.0.14-15-pve installed and unbooted on both. The old one-line
# test called that "skew", then ran a dist-upgrade — moving this node AHEAD of the peer,
# i.e. manufacturing the exact skew the gate exists to prevent — and finally re-compared
# the still-unchanged running kernel and exited 2 with "still skewed after upgrade". No
# amount of upgrading could pass it, and every attempt made the real divergence worse.
# Compare what portable-dotnet-architecture/proxmox-lab/OPERATIONS.md#planned-maintenance compares: the package list, minus the
# running-kernel parenthetical and the per-kernel -pve-signed lines (those differ until
# both nodes have rebooted; the kernel is Gate 1's business, above).
PKGSET="pveversion -v | grep -v '^proxmox-kernel-[0-9].*-pve-signed:' | sed 's/ (running kernel: .*)//'"
LOCAL_VER=$(eval "$PKGSET"); PEER_VER=$(peer "$PKGSET")
if [ "$LOCAL_VER" = "$PEER_VER" ]; then
    ok "package sets match the peer (pve-manager $(pveversion -v | awk '/^pve-manager:/ {print $2}'))"
else
    bad "package skew between this node and the peer:"
    diff <(printf '%s\n' "$LOCAL_VER") <(printf '%s\n' "$PEER_VER") | sed 's/^/       /'
    echo "       Live migration from the peer's newer QEMU onto this older one can fail."
    if confirm "Run 'apt update && apt dist-upgrade' on this node now?"; then
        apt update && apt dist-upgrade -y
        if reboot_pending; then
            bad "the upgrade landed $(newest_installed_kernel) — reboot this node, then re-run node-return."
            exit 2
        fi
        if [ "$(eval "$PKGSET")" != "$PEER_VER" ]; then
            bad "still skewed after the upgrade — which means the PEER is the one behind the repo."
            bad "  Run 'apt update && apt dist-upgrade' on $PEER_NAME too, then re-run node-return."
            bad "  Do not migrate in the meantime: this node is now the newer of the two."
            exit 2
        fi
        ok "aligned: pve-manager $(pveversion -v | awk '/^pve-manager:/ {print $2}')"
    else
        exit 2
    fi
fi

# ── Gate 3: replication caught up (16.2 step 3) ──────────────────────────────
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
echo "       Reminder: do NOT 'qm start' anything on this node — its local disks are stale until replication is current (16.2)."

[ "$CHECK" = 1 ] && { say "--check done — no changes made."; exit 0; }

# ── Step 4: move workload back, live (16.2 step 5) ───────────────────────────
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

# ── Step 5: scrub after the idle period (16.2 step 6) ────────────────────────
say "Scrub"
if confirm "The pools sat idle — start 'zpool scrub apps && zpool scrub db' now (runs in background)?"; then
    zpool scrub apps 2>/dev/null || true
    zpool scrub db   2>/dev/null || true
    ok "scrubs started — progress: zpool status"
fi

say "Done. Finish with a full sweep: cluster-health"
