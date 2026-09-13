#!/usr/bin/env bash
# cluster-health.sh — the 18.7 health checks as one command, plus the ones that
# are easy to forget: pool capacity, pinned snapshots, the fencing watchdog,
# version skew between the nodes, firmware, NVMe wear, power state. Run it on
# either node; a few checks are node-aware (UPS on pve1, battery on pve2).
#
# Output: one line per check, [ OK ] / [WARN] / [FAIL].
# Exit:   0 = all OK, 1 = warnings, 2 = at least one failure.
#
# Usage: cluster-health [--quiet]
#   --quiet   print only WARN/FAIL lines — for cron with MAILTO, so a healthy
#             cluster sends no mail and a sick one sends exactly the problems.
#
# THE RULE EVERY CHECK BELOW OBEYS, learned the expensive way on 2026-09-10:
# a check may only report what it actually observed. An empty result set is not a
# pass. A command that did not run is not a pass. A question about the peer that
# this node cannot answer is not a pass. Every branch that used to shrug — the
# missing tool, the zero-length list, the "it must be on the other node" — now
# either says what it does not know, or asks a differently-shaped question that
# this node genuinely can answer (cluster-wide config in pmxcfs, rather than local
# mounts). The failure being guarded against is not a check that breaks loudly;
# it is a check that keeps printing [ OK ] long after it stopped looking.

set -uo pipefail

# A script that cannot work without /usr/sbin has no business depending on its caller to
# supply it. The cron file sets PATH as well, and should — but cron is not the only
# caller. systemd timers, `at`, `ansible raw`, `su -c` and a hand-edited crontab all
# bypass /etc/cron.d/pve-helper-scripts entirely, and each of them would reintroduce the
# 2026-09-10 failure whole. Prepend rather than replace, so anything a caller legitimately
# added still resolves.
PATH=/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}
export PATH

POOLS="apps db"
CAPACITY_WARN=80          # % pool usage that triggers a warning
SNAPSHOT_WARN_GB=50       # a single snapshot pinning more than this → warning
NVME_WEAR_WARN=85         # % NVMe endurance used
BACKUP_MAX_AGE_H=26       # newest vzdump older than this → warning
REPL_STALE_H=26           # a recurring replication job silent this long → the scheduler died
USB_MOUNT=/mnt/usb-backup
AUTOSTART_VMS="1021 1022 1023"   # must have onboot=1 (10-vms.md); 1020 is manual by design

# Corosync links that are plugged in on purpose and unplugged again afterwards, so
# "disconnected" is their resting state rather than an incident. Link 1 is the 10G
# direct cable (5.4): it exists to make a migration fast, not to carry membership,
# and it spends most of its life out of the socket. Link 0 — the LAN ring — is the
# one that must never be down, and it is deliberately NOT in this list.
ON_DEMAND_LINKS="1"

QUIET=0
[ "${1:-}" = "--quiet" ] && QUIET=1

RC=0
record() { :; }
if [ -n "${INFRA_CHECKS_FILE:-}" ]; then
    helper="$(dirname "${BASH_SOURCE[0]}")/infra-check-output"
    [ -r "$helper" ] || helper="$helper.sh"
    # shellcheck source=infra-check-output.sh
    . "$helper" || exit 2
fi
ok()   { record pass "$1"; [ "$QUIET" = 1 ] || printf '[ OK ] %s\n' "$1"; }
warn() { record warn "$1"; printf '[WARN] %s\n' "$1"; [ "$RC" -lt 1 ] && RC=1; return 0; }
fail() { record fail "$1"; printf '[FAIL] %s\n' "$1"; RC=2; return 0; }

# ── Tool guards ───────────────────────────────────────────────────────────────
# Every check below shells out, and until 2026-09-10 none of them checked that the
# command existed. Cron's PATH is /usr/bin:/bin, which does not contain /usr/sbin,
# so smartctl, corosync-cfgtool, ha-manager, qm, dmidecode and lsmod were all simply
# absent at 07:00 — and the failures were silent in BOTH directions, which is the
# part worth remembering:
#
#   smartctl missing         → no "PASSED" in the empty output → [FAIL] on a healthy disk
#   corosync-cfgtool missing → no "faulty" in the empty output → [ OK ] on a dead ring
#   ha-manager / qm missing  → empty result sets → [ OK ], or the check skipped entirely
#
# So the nightly mail screamed about four perfectly good NVMe drives while reporting
# that a corosync link which had been down for six days was healthy. A check that
# cannot run must say so loudly and by name; it must never render a verdict about
# hardware it never spoke to. install-scripts.sh now sets PATH in the cron file, and
# this is the belt to that pair of braces — it also catches a genuinely uninstalled
# package, which is a real thing that happens (fwupd on pve1).
have()    { command -v "$1" >/dev/null 2>&1; }
require() {
    have "$1" && return 0
    CHECK_OBSERVATION=unknown fail "$2: '$1' is not on PATH — this check DID NOT RUN, so treat it as unknown, not as passing (PATH=$PATH)"
    return 1
}

# ── Quorum ────────────────────────────────────────────────────────────────────
CHECK_ID=quorum CHECK_CATEGORY=cluster
if require pvecm "quorum"; then
    PVECM=$(pvecm status 2>&1)
    if echo "$PVECM" | grep -q 'Quorate:.*Yes'; then
        TOTAL=$(echo "$PVECM" | awk '/Total votes:/ {print $3}')
        EXPECTED=$(echo "$PVECM" | awk '/Expected votes:/ {print $3}')
        if [ "${TOTAL:-0}" = "${EXPECTED:-3}" ]; then
            ok "quorum: quorate, $TOTAL/$EXPECTED votes"
        else
            warn "quorum: quorate but only $TOTAL/$EXPECTED votes — a node or the QDevice is missing; no margin until it's back"
        fi
    else
        fail "quorum: NOT quorate — see 18.5 before touching anything"
    fi
fi

# ── Corosync rings ────────────────────────────────────────────────────────────
CHECK_ID=corosync CHECK_CATEGORY=network
# Judged per link, not with one grep over the whole output, because the two links
# do not mean the same thing. Link 0 is the LAN ring: membership rides on it and it
# being down is an incident. Link 1 is the 10G direct cable (5.4), which is plugged
# in for a migration and pulled out again — it is disconnected almost all the time
# BY DESIGN, and a check that warns about it every single night is a check the
# operator learns to skim past, which is how the genuinely interesting line gets
# missed. ON_DEMAND_LINKS at the top decides which is which.
#
# corosync-cfgtool -s prints a "LINK ID <n>" header followed by one line per peer
# whose status is connected / disconnected; a link with no reachable peer is down.
if require corosync-cfgtool "corosync"; then
    LINK_STATES=$(corosync-cfgtool -s 2>&1 | awk '
        /^LINK ID/  { if (id != "") print id, (down ? "down" : "up"); id = $3; down = 0; next }
        /disconnected|FAULTY|faulty/ { down = 1 }
        END         { if (id != "") print id, (down ? "down" : "up") }')
    DOWN_REQUIRED=""
    DOWN_ONDEMAND=""
    LINKS_UP=0
    while read -r lid lstate; do
        [ -n "$lid" ] || continue
        if [ "$lstate" = "up" ]; then
            LINKS_UP=$((LINKS_UP + 1))
            continue
        fi
        case " $ON_DEMAND_LINKS " in
            *" $lid "*) DOWN_ONDEMAND="$DOWN_ONDEMAND $lid" ;;
            *)          DOWN_REQUIRED="$DOWN_REQUIRED $lid" ;;
        esac
    done <<EOF
$LINK_STATES
EOF
    if [ -n "$DOWN_REQUIRED" ]; then
        fail "corosync: link(s)$DOWN_REQUIRED DOWN — these carry cluster membership, not just throughput (corosync-cfgtool -s, then 5.3)"
    elif [ "$LINKS_UP" -eq 0 ]; then
        fail "corosync: no link reported up at all — parse corosync-cfgtool -s by hand before trusting anything else here"
    elif [ -n "$DOWN_ONDEMAND" ]; then
        ok "corosync: membership link(s) healthy; on-demand link(s)$DOWN_ONDEMAND unplugged as expected (5.4)"
    else
        ok "corosync: all $LINKS_UP link(s) healthy"
    fi
fi

# ── ZFS pools: health, capacity, pinned snapshots ─────────────────────────────
CHECK_ID=zfs CHECK_CATEGORY=storage
# Worth knowing while reading these lines: every pool here is a SINGLE-DEVICE vdev,
# no mirror and no raidz (6.1). "all pools healthy" therefore means "the one disk
# under each pool has not failed yet" — it is not a redundancy statement. The whole
# resilience story rests on replication to the peer and on the backup tiers, which
# is exactly why the two checks below them are the ones that must never lie.
if require zpool "zfs"; then
    ZHEALTH=$(zpool status -x 2>&1)
    if [ "$ZHEALTH" = "all pools are healthy" ]; then
        ok "zfs: all pools healthy (single-device vdevs — no redundancy by design, 6.1)"
    else
        fail "zfs: $(echo "$ZHEALTH" | head -1) — run zpool status"
    fi

    # Inside the guard, deliberately. These two loops used to sit outside it, which
    # reintroduced both halves of the very bug this script was rewritten to kill: with
    # zpool missing, every pool reported "not found" (a FAIL about hardware nobody
    # queried), and with zfs missing the snapshot check found nothing in an empty string
    # and printed [ OK ]. Guards only work where the commands actually are.
    for pool in $POOLS; do
        CAP=$(zpool list -H -o capacity "$pool" 2>/dev/null | tr -d '%')
        if [ -z "$CAP" ]; then
            fail "zfs: pool '$pool' not found — replication has nowhere to go (Stage 6)"
        elif [ "$CAP" -ge "$CAPACITY_WARN" ]; then
            warn "zfs: pool '$pool' at ${CAP}% — investigate before it becomes an outage (pinned snapshots? see 16.2)"
        else
            ok "zfs: pool '$pool' at ${CAP}%"
        fi
    done
fi

# `zfs` is a separate binary from `zpool` and needs its own guard. `-p` asks for exact
# bytes rather than the human-readable form: the old awk matched only a `G` suffix, so a
# snapshot measured in T — the only size that would ever really matter here — sailed past
# the check entirely, and one measured in M was compared as though it were gigabytes.
if require zfs "zfs-snapshots"; then
    SNAP_RAW=$(zfs list -t snapshot -H -p -o name,used 2>&1)
    SNAP_RC=$?
    if [ "$SNAP_RC" -ne 0 ]; then
        fail "zfs: could not list snapshots (exit $SNAP_RC) — pinned-snapshot growth is UNKNOWN, not absent: $(echo "$SNAP_RAW" | head -1)"
    else
        BIG_SNAPS=$(echo "$SNAP_RAW" | awk -v lim="$SNAPSHOT_WARN_GB" '
            $2 + 0 > lim * 1073741824 { printf "%s (%.1fG) ", $1, $2 / 1073741824 }')
        if [ -n "$BIG_SNAPS" ]; then
            warn "zfs: large pinned snapshot(s): $BIG_SNAPS— a stale replication or forgotten qm snapshot (16.2 / 20.3)"
        else
            ok "zfs: no snapshot over ${SNAPSHOT_WARN_GB}G"
        fi
    fi
fi

# ── Replication ───────────────────────────────────────────────────────────────
CHECK_ID=replication CHECK_CATEGORY=replication
# Columns: JobID Enabled Target LastSync NextSync Duration FailCount State
#
# SYNCING IS NOT A FAILURE. pvesr builds that last column as
#     my $state = $job->{pid} ? "SYNCING" : $job->{error} // 'OK';
# (/usr/share/perl5/PVE/CLI/pvesr.pm) — so the column is exactly one of "SYNCING"
# (a sync holds a pid right now), "OK", or the literal error text of the last run.
# The old test was `$8 != "OK"`, which made a perfectly normal in-flight sync read
# as "your RPO is drifting right now". Because the jobs are scheduled `*:0` and the
# check used to run at 07:00:01, it caught one nearly every morning: months of a
# daily red mail that meant nothing, which is the most expensive kind of alert.
# The cron entry also moved to 07:07, which removes the collision with the `*:0` jobs
# but NOT the race in general: job 1022-0 is scheduled `*/1` and fires 1440 times a day,
# so no cron minute can dodge it. The SYNCING rule above is the actual fix; 07:07 is only
# tidiness on top of it. (Said plainly because the first draft of this comment claimed
# the move had settled it, which would have sent the next operator looking in the wrong place.)
#
# State can be a multi-word error message, so it is rebuilt from field 8 to the end
# rather than read as $8 — otherwise only the first word of an error is compared.
#
# THREE FAILURES THAT "State == OK" DOES NOT COVER, all of them worse than a failed run
# because they are indistinguishable from health:
#   Enabled=No     — a disabled job is still LISTED, with FailCount 0 and State OK
#                    (PVE::API2::Replication calls job_status(1), i.e. include-disabled).
#                    Somebody switching replication off reads as "all jobs healthy", and
#                    with no backups and single-disk vdevs, replication is the only second
#                    copy of the data. This is the one you most need to catch.
#   LastSync='-'   — configured but never once run.
#   stale LastSync — State describes the LAST run, not whether runs still happen. If
#                    pvescheduler dies, LastSync freezes and State stays OK forever while
#                    this check cheerfully claims to be watching your RPO.
# The staleness test is applied only to jobs whose schedule starts with `*` — the recurring
# sub-daily ones, which today is all four (three `*:0` and 1022-0 on `*/1`). The filter is
# there for the schedule that is not: a `sun 05:00` job is legitimately a week stale, and a
# single threshold loose enough to accommodate one would be far too loose to catch a dead
# scheduler on the others. Add a weekly job and this check quietly keeps being correct.
if require pvesr "replication"; then
    REPL=$(pvesr status 2>&1)
    JOB_SCHED=$(awk '/^local:/ {job=$2} /^[[:space:]]*schedule[[:space:]]/ {print job "=" $2}' \
        /etc/pve/replication.cfg 2>/dev/null)
    NOW=$(date +%s)
    BAD_JOBS=""
    STALE_JOBS=""
    SYNCING=""
    JOBS_HERE=0
    while IFS='|' read -r jid jen jlast jfail jstate; do
        [ -n "$jid" ] || continue
        JOBS_HERE=$((JOBS_HERE + 1))
        [ "$jstate" = "SYNCING" ] && SYNCING="x$SYNCING"
        if [ "$jen" = "No" ]; then
            BAD_JOBS="$BAD_JOBS $jid(DISABLED)"
        elif [ "${jfail:-0}" -gt 0 ] 2>/dev/null; then
            BAD_JOBS="$BAD_JOBS $jid($jstate, fails=$jfail)"
        elif [ "$jstate" != "OK" ] && [ "$jstate" != "SYNCING" ]; then
            BAD_JOBS="$BAD_JOBS $jid($jstate)"
        elif [ "$jlast" = "-" ]; then
            BAD_JOBS="$BAD_JOBS $jid(NEVER SYNCED)"
        else
            case "$JOB_SCHED" in
                *"$jid=*"*)
                    LAST_EPOCH=$(date -d "$(echo "$jlast" | tr '_' ' ')" +%s 2>/dev/null)
                    if [ -n "$LAST_EPOCH" ]; then
                        AGE_H=$(( (NOW - LAST_EPOCH) / 3600 ))
                        [ "$AGE_H" -gt "$REPL_STALE_H" ] && STALE_JOBS="$STALE_JOBS $jid(${AGE_H}h)"
                    fi
                    ;;
            esac
        fi
    done <<EOF
$(echo "$REPL" | awk 'NR > 1 && NF >= 8 {
    st = ""
    for (i = 8; i <= NF; i++) st = st (i > 8 ? " " : "") $i
    print $1 "|" $2 "|" $4 "|" $7 "|" st
}')
EOF
    SYNCING=${#SYNCING}
    [ "$SYNCING" -eq 0 ] && SYNCING=""
    # replication.cfg lives in pmxcfs, so this answers the CLUSTER-wide question even
    # from the node that runs none of the jobs — "none here" and "none anywhere" are
    # very different sentences and the old check could not tell them apart.
    # grep -c prints a number whenever the file exists (and exits 1 on zero matches,
    # hence no `|| echo 0`, which would have appended a second line and broken the test).
    JOBS_CLUSTER=$(grep -c '^local:' /etc/pve/replication.cfg 2>/dev/null)
    JOBS_CLUSTER=${JOBS_CLUSTER:-0}
    if [ -n "$BAD_JOBS" ]; then
        fail "replication:$BAD_JOBS — your RPO is drifting right now (pvesr status)"
    elif [ -n "$STALE_JOBS" ]; then
        fail "replication:$STALE_JOBS since the last successful sync, with no error recorded — that shape means the scheduler stopped running the job, not that the job failed (systemctl status pvescheduler)"
    elif [ "$JOBS_HERE" -gt 0 ]; then
        ok "replication: all $JOBS_HERE job(s) healthy${SYNCING:+ ($SYNCING syncing right now)}"
    elif [ "${JOBS_CLUSTER:-0}" -gt 0 ]; then
        ok "replication: no jobs run on this node; $JOBS_CLUSTER configured cluster-wide and owned by the peer (replication.cfg)"
    else
        fail "replication: NO replication job exists anywhere in the cluster — a node loss would lose everything since the last backup (Stage 12)"
    fi
fi

# ── HA ────────────────────────────────────────────────────────────────────────
CHECK_ID=ha CHECK_CATEGORY=guests
# The old test was "is any service line NOT started?", which answers [ OK ] just as
# happily when there are no service lines at all — whether because HA was never
# configured or because ha-manager itself could not be found (which is precisely
# what happened under cron until 2026-09-10). An empty result set is not a pass, so
# the count is now part of the verdict.
if require ha-manager "ha"; then
    HA_STATUS=$(ha-manager status 2>/dev/null)
    HA_SERVICES=$(echo "$HA_STATUS" | grep -c '^service')
    HA_BAD=$(echo "$HA_STATUS" | grep '^service' | grep -v started || true)
    if [ "${HA_SERVICES:-0}" -eq 0 ]; then
        warn "ha: no HA services at all — nothing is being restarted automatically after a node loss (Stage 15)"
    elif [ -n "$HA_BAD" ]; then
        warn "ha: not all services started: $(echo "$HA_BAD" | tr '\n' ' ')"
    else
        ok "ha: all $HA_SERVICES service(s) started"
    fi
fi

# Placement flags. `failback` and `auto-rebalance` both default to 1 and come
# back on silently every time a resource is re-added (17.7 step 2, 19.2 step 8).
# On, they let the cluster move a guest by itself the moment a node affinity
# rule or CRS rebalancing is switched on — and on this build a guest that drifts
# to pve2 stops being backed up (15.5). Cluster-wide config: either node sees it.
# `have`, not `require`: if ha-manager is missing the check above has already said so
# once and loudly, and a second FAIL for the same cause is noise. The zero-resource
# case is likewise already covered above — this block is the only one in the script
# allowed to skip quietly, and only because something else is shouting.
HA_CONF=$(have ha-manager && ha-manager config 2>/dev/null)
HA_COUNT=$(echo "$HA_CONF" | grep -c '^vm:')
if [ "${HA_COUNT:-0}" -gt 0 ]; then
    FB=$(echo "$HA_CONF" | grep -c 'failback 0')
    AR=$(echo "$HA_CONF" | grep -c 'auto-rebalance 0')
    if [ "$FB" -lt "$HA_COUNT" ] || [ "$AR" -lt "$HA_COUNT" ]; then
        warn "ha: placement flags not cleared on every resource (failback $FB/$HA_COUNT, auto-rebalance $AR/$HA_COUNT) — ha-manager config, then 15.5"
    else
        ok "ha: placement flags cleared on all $HA_COUNT resources"
    fi
fi

# ── Watchdog (fencing) ────────────────────────────────────────────────────────
CHECK_ID=watchdog CHECK_CATEGORY=cluster
# Self-fencing is what makes automatic recovery safe rather than reckless (18.2),
# and it is the one piece of the HA stack that fails completely silently: nothing
# in the UI, and nothing else in this script, reports a watchdog that never got
# armed. You would find out during the incident. 15.4 has the detail.
if systemctl is-active --quiet watchdog-mux; then
    # lsmod is /usr/sbin and so was invisible under the old cron PATH; it only decorates
    # the line with the driver name, so `have` is enough and its absence changes nothing
    # about the verdict.
    WD_MOD=$(have lsmod && lsmod | awk '/^(softdog|iTCO_wdt|wdat_wdt|sp5100_tco)[[:space:]]/ {print $1}' | head -1)
    ok "watchdog: watchdog-mux running${WD_MOD:+ ($WD_MOD)}"
else
    fail "watchdog: watchdog-mux NOT running — a node that loses quorum will not fence itself (15.4)"
fi

# ── Start at boot ─────────────────────────────────────────────────────────────
CHECK_ID=autostart CHECK_CATEGORY=guests
# HA guests are started by the HA stack; every other VM comes back after a node
# reboot only if onboot is set. Nothing else surfaces a missing flag — you find
# out the next time you reboot (10-vms.md, "Start at boot"). Node-local: VMs
# living on the peer are its own run's business.
#
# The `|| continue` below is load-bearing and was also the trap: it means "this VM is
# not on this node", which is legitimate — but under the old cron PATH `qm` itself was
# missing, so EVERY VM took that branch and the check reported [ OK ] having examined
# nothing at all. Counting what was actually inspected is what makes the difference
# visible; an empty sample is now stated as an empty sample.
if require qm "autostart"; then
    NO_ONBOOT=""
    CHECKED=0
    for id in $AUTOSTART_VMS; do
        CONF=$(qm config "$id" 2>/dev/null) || continue     # not on this node
        CHECKED=$((CHECKED + 1))
        echo "$CONF" | grep -q '^onboot: 1' || NO_ONBOOT="$NO_ONBOOT $id"
    done
    if [ -n "$NO_ONBOOT" ]; then
        warn "autostart:$NO_ONBOOT would stay stopped after a node reboot — qm set <id> --onboot 1 (Stage 10)"
    elif [ "$CHECKED" -eq 0 ]; then
        ok "autostart: none of the VMs ($AUTOSTART_VMS) live on this node — the peer's run covers them"
    else
        ok "autostart: all $CHECKED VM(s) on this node are set to start at boot"
    fi
fi

# ── Version skew vs the peer node ─────────────────────────────────────────────
CHECK_ID=versions CHECK_CATEGORY=maintenance
PEER_LINE=$(awk -v me="$(hostname)" '
    /node {/ {name=""; addr=""}
    $1 == "name:" {name=$2}
    $1 == "ring0_addr:" {addr=$2}
    /}/ { if (name != "" && name != me && addr != "") print name, addr }' /etc/pve/corosync.conf | head -1)
PEER_NAME=${PEER_LINE%% *}
PEER_ADDR=${PEER_LINE##* }
if [ -n "$PEER_ADDR" ]; then
    # Resolve the peer's host key the way PVE itself does, not the way a human does.
    # This check used to be a plain `ssh root@$PEER_ADDR`, which leans on /root/.ssh and
    # /etc/ssh — and pve2 has neither a /root/.ssh/known_hosts nor the legacy
    # /etc/ssh/ssh_known_hosts symlink, so from that node the check failed with "Host key
    # verification failed" every single night for weeks. Worse than failing, it *explained
    # itself away*: the old message read "node down, or during maintenance: expected",
    # which is precisely the kind of reassuring parenthesis that stops anyone from
    # looking. It was neither (2026-09-10).
    #
    # PVE::SSHInfo::ssh_info_to_ssh_opts uses /etc/pve/nodes/<node>/ssh_known_hosts with
    # HostKeyAlias=<node>. That file is written by `pvecm updatecerts`, is distributed by
    # pmxcfs so both nodes always have both keys, and is what makes migration and
    # replication work regardless of the state of anyone's ~/.ssh. Mirroring it here means
    # this check now answers the same question the cluster itself answers — and a failure
    # is real news rather than a local ssh-config accident. The -f test mirrors SSHInfo's
    # own, for a node whose file has not been generated yet.
    PEER_KH="/etc/pve/nodes/$PEER_NAME/ssh_known_hosts"
    KH_OPTS=""
    [ -f "$PEER_KH" ] && KH_OPTS="-o UserKnownHostsFile=$PEER_KH -o GlobalKnownHostsFile=none"
    # shellcheck disable=SC2086  # KH_OPTS is a deliberate word-split option pair
    PEER_VER=$(ssh -o BatchMode=yes -o ConnectTimeout=5 -o HostKeyAlias="$PEER_NAME" \
        $KH_OPTS "root@$PEER_ADDR" pveversion 2>/dev/null)
    LOCAL_VER=$(pveversion)
    if [ -z "$PEER_VER" ]; then
        warn "versions: peer $PEER_NAME ($PEER_ADDR) did not answer SSH — expected only if it is genuinely down; otherwise regenerate its key file with 'pvecm updatecerts' on BOTH nodes and re-run (21.4)"
    elif [ "$PEER_VER" = "$LOCAL_VER" ]; then
        ok "versions: both nodes on $LOCAL_VER"
    else
        warn "versions: skew — local $LOCAL_VER vs peer $PEER_VER. Migrate old→new only; align before returning workload (16.2)"
    fi
else
    warn "versions: could not find a peer in corosync.conf"
fi

# ── Running kernel vs installed kernel ────────────────────────────────────────
CHECK_ID=kernel CHECK_CATEGORY=maintenance
# The peer comparison above reads `pveversion`, which reports the RUNNING kernel — so two
# nodes can agree with each other perfectly while BOTH have a newer kernel installed and
# unbooted, which is exactly the state this cluster was in (7.0.14-15-pve sitting in /boot
# on both, one node running -12 and the other -8, 19 days up). Nothing said so, because
# nothing looked at /boot.
#
# It matters because of who ends up choosing the moment. An unbooted kernel is a reboot you
# have already committed to and not yet scheduled; if you never schedule it, the reboot you
# get is the one HA hands you during a fence — unattended, unwatched, and onto a kernel
# this hardware has never once run.
RUNNING_K=$(uname -r)
NEWEST_K=$(ls -1 /boot/vmlinuz-* 2>/dev/null | sed 's|.*/vmlinuz-||' | sort -V | tail -1)
if [ -z "$NEWEST_K" ]; then
    warn "kernel: could not read /boot — cannot tell whether a newer kernel is waiting for a reboot"
elif [ "$NEWEST_K" != "$RUNNING_K" ]; then
    warn "kernel: running $RUNNING_K but $NEWEST_K is installed and unbooted — schedule that reboot instead of letting a fence pick the moment (20.2)"
else
    ok "kernel: running the newest installed ($RUNNING_K)"
fi

# ── Plain node-to-node SSH (the human path) ───────────────────────────────────
CHECK_ID=ssh CHECK_CATEGORY=network
# Checked separately from the version comparison above, and the separation is the
# whole point: the two use completely different host-key stores and can disagree
# for months without anything noticing. PVE's own tooling carries
# /etc/pve/nodes/<node>/ssh_known_hosts with every call, so migration, replication
# and `pvecm` keep working perfectly. A human typing `ssh pve1` gets none of that —
# they get /root/.ssh/known_hosts and /etc/ssh/ssh_known_hosts, which are per-node,
# unmanaged, and on this cluster were simply absent on pve2. Migration was fine;
# the operator was locked out; and because the version check above now (correctly)
# uses the PVE store, it will no longer be the thing that trips over it.
#
# WARN, not FAIL: nothing automated depends on this. It is on the list because the
# person who needs to hop to the peer by hand needs it during an incident, which is
# the worst possible moment to discover a missing host key — and because a silent
# gap between "the cluster can" and "you can" is exactly the class of trap this
# script exists to surface.
if [ -n "${PEER_ADDR:-}" ]; then
    if ssh -o BatchMode=yes -o ConnectTimeout=5 "root@$PEER_ADDR" true 2>/dev/null; then
        ok "ssh: plain 'ssh root@$PEER_ADDR' works from this node"
    else
        warn "ssh: plain 'ssh root@$PEER_ADDR' fails from this node — PVE's own migration and replication are unaffected (they carry their own known_hosts), but you cannot hand-type your way to the peer during an incident (21.4)"
    fi
fi

# ── Firmware ──────────────────────────────────────────────────────────────────
CHECK_ID=firmware CHECK_CATEGORY=maintenance
# Detection only — nothing here ever flashes anything (16.3: flashing is a
# planned window, per machine, on a reason). fwupd refreshes LVFS metadata on
# its own timer and this just reads the result. A machine LVFS doesn't cover
# reports zero forever, which is NOT the same as being current — that one stays
# a quarterly look at the vendor's page.
#
# A pending release is an ADVISORY warning. 16.3's policy is that "there's a newer version
# out" is not a reason to flash, so a release on LVFS is information for the next planned
# window rather than a fault: the app records it without turning the node yellow (platform
# ADR-0015 D4b — observed maintenance warnings only). The branches that could not ask stay
# plain warnings — no metadata, no device list, an unreadable answer — because those are
# monitoring gaps, not maintenance facts.
#
# UEFI dbx is judged against Secure Boot. dbx is the list of revoked boot signatures, and the
# firmware consults it only while Secure Boot is enforcing. pve2 runs with Secure Boot off, so
# its pending dbx release protected nothing, could not be applied either, and still kept the
# node warning after the 2026-09-13 BIOS flash had cleared everything else. With Secure Boot
# off the release is named in the line instead of counted; with it on — or with its state
# unreadable — it counts like any other device, and 16.3's "take dbx updates last" applies.
BIOS_VER=$(have dmidecode && dmidecode -s bios-version 2>/dev/null | head -1)
SB_VAR=/sys/firmware/efi/efivars/SecureBoot-8be4df61-93ca-11d2-aa0d-00e098032b8c
SB_STATE=unknown
if [ -r "$SB_VAR" ]; then
    # efivarfs: four attribute bytes, then the one data byte — 1 enforcing, 0 not.
    case "$(od -An -t u1 "$SB_VAR" 2>/dev/null | awk '{print $NF}')" in
        1) SB_STATE=on ;;
        0) SB_STATE=off ;;
    esac
fi
if have fwupdmgr; then
    # `have` proves the binary exists; it does not prove the query worked, and those are
    # different claims. If the fwupd daemon is stopped or errors, --json emits an error
    # object instead of a device list, the old `grep -c '"Releases"'` found nothing in it,
    # and the check printed the same cheerful "nothing pending" as a genuinely clean run —
    # the exact shape of the corosync bug, one command over. So the answer is validated
    # before it is counted: no "Devices" object means the question was not answered.
    FW_OUT=$(fwupdmgr get-updates --json 2>&1)
    # "Nothing pending" and "nothing known" are not the same answer. If LVFS metadata was
    # never downloaded there is nothing to compare against, and the device list comes back
    # cleanly empty — the same green line as a genuinely current machine. pve1 had no
    # /var/lib/fwupd/metadata at all on 2026-09-10 while reporting nothing pending.
    if [ ! -d /var/lib/fwupd/metadata ] || [ -z "$(ls -A /var/lib/fwupd/metadata 2>/dev/null)" ]; then
        warn "firmware: no LVFS metadata on this node, so 'nothing pending' would mean 'nothing known' — run 'fwupdmgr refresh' and re-check (16.3)"
    elif ! echo "$FW_OUT" | grep -q '"Devices"'; then
        warn "firmware: fwupdmgr did not return a device list, so pending updates are UNKNOWN rather than absent — check 'systemctl status fwupd': $(echo "$FW_OUT" | grep -v '^$' | head -1)"
    # One line per device that has a release: plugin, name, running version, offered version.
    # Decoded from the first brace, because stderr is merged into FW_OUT and a fwupd warning
    # line can precede the JSON. Counting '"Releases"' by grep could not tell dbx from a BIOS.
    elif ! FW_PENDING=$(printf '%s' "$FW_OUT" | python3 -c 'import json, sys
text = sys.stdin.read()
data, _ = json.JSONDecoder().raw_decode(text[text.index("{"):])
for device in data.get("Devices", []):
    releases = device.get("Releases") or []
    if releases:
        print("\t".join(str(field) for field in (device.get("Plugin") or "", device.get("Name") or "?",
                                                   device.get("Version") or "?", releases[0].get("Version") or "?")))' 2>&1); then
        CHECK_OBSERVATION=unknown warn "firmware: fwupdmgr answered but its device list could not be read, so pending updates are UNKNOWN rather than absent: $(echo "$FW_PENDING" | tail -1)"
    else
        FW_DBX_NOTE=""
        if [ "$SB_STATE" = off ]; then
            FW_DBX_NOTE=$(printf '%s\n' "$FW_PENDING" | awk -F '\t' '$1 == "uefi_dbx" {print "; UEFI dbx " $3 " -> " $4 " is available but inert: Secure Boot is off, so the firmware never reads it"; exit}')
            FW_PENDING=$(printf '%s\n' "$FW_PENDING" | awk -F '\t' 'NF && $1 != "uefi_dbx"')
        fi
        FW_COUNT=$(printf '%s\n' "$FW_PENDING" | grep -c .)
        if [ "$FW_COUNT" -gt 0 ]; then
            FW_LIST=$(printf '%s\n' "$FW_PENDING" | awk -F '\t' 'NF {printf "%s%s %s -> %s", (n++ ? ", " : ""), $2, $3, $4}')
            CHECK_ADVISORY=true warn "firmware: $FW_COUNT device(s) with an update on LVFS ($FW_LIST)$FW_DBX_NOTE — advisory: read 16.3 before flashing; it is a maintenance window, not an apt run, and a newer version alone is not a reason to flash"
        else
            ok "firmware: nothing pending on LVFS${BIOS_VER:+ (BIOS $BIOS_VER)}$FW_DBX_NOTE"
        fi
    fi
else
    warn "firmware: fwupd not installed — no detection at all on this node (2.2)"
fi

# ── Time sync ─────────────────────────────────────────────────────────────────
CHECK_ID=clock CHECK_CATEGORY=host
if [ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null)" = "yes" ]; then
    ok "time: synchronized"
else
    warn "time: NOT synchronized — expect confusing logs and cert complaints (timedatectl)"
fi

# ── Backups ───────────────────────────────────────────────────────────────────
CHECK_ID=backup-schedule CHECK_CATEGORY=backups
# Two questions, cluster-wide one first, and that ordering is the whole fix.
#
# The old check only asked the node-local one — "is the USB drive mounted HERE?" —
# and its else-branch printed "[ OK ] backup: no USB storage on this node (it lives
# on the peer)". That sentence is a guess dressed as a verdict: the node cannot see
# the peer, so it asserts something it did not check. On 2026-09-10 that branch
# fired on BOTH nodes, because no node had the drive at all — two green lines, no
# USB anywhere, no backup job configured anywhere, and not a single vzdump in the
# entire task history. A per-node question can never detect a cluster-wide absence.
#
# /etc/pve/jobs.cfg and /etc/pve/vzdump.cron both live in pmxcfs and read identically
# on either node, so the "is anything scheduled AT ALL?" question can be answered
# from here honestly, and it is the one that actually matters.
JOBS_MODERN=$(grep -c '^vzdump:' /etc/pve/jobs.cfg 2>/dev/null)
JOBS_LEGACY=$(grep -cE '^[^#]*[[:space:]]vzdump[[:space:]]' /etc/pve/vzdump.cron 2>/dev/null)
BACKUP_JOBS=$(( ${JOBS_MODERN:-0} + ${JOBS_LEGACY:-0} ))

if [ "$BACKUP_JOBS" -eq 0 ]; then
    fail "backup: NO vzdump job is scheduled anywhere in the cluster — nothing is being backed up, on either node (17.3)"
else
    ok "backup: $BACKUP_JOBS vzdump job(s) scheduled cluster-wide"
fi

if mountpoint -q "$USB_MOUNT"; then
    NEWEST=$(find "$USB_MOUNT/dump" -name 'vzdump-qemu-*' -mmin -$((BACKUP_MAX_AGE_H * 60)) 2>/dev/null | head -1)
    if [ -n "$NEWEST" ]; then
        ok "backup: fresh vzdump on the USB drive (<${BACKUP_MAX_AGE_H}h) — backup-verify has the per-VM detail"
    else
        warn "backup: no vzdump newer than ${BACKUP_MAX_AGE_H}h on $USB_MOUNT — check the job and its notifications (17.3)"
    fi
elif [ -d "$USB_MOUNT" ]; then
    fail "backup: $USB_MOUNT exists but nothing is mounted there — the USB drive dropped off (17.2)"
elif [ "$BACKUP_JOBS" -gt 0 ]; then
    ok "backup: no USB drive on this node; a job is scheduled cluster-wide, so the peer's backup-verify run is the authority"
fi
# No else. When there is no drive here AND no job anywhere, the FAIL above already
# said the only true thing there is to say, and repeating a reassurance underneath it
# is how the original bug read as normal for as long as it did.

# ── NVMe health and wear ──────────────────────────────────────────────────────
CHECK_ID=disks CHECK_CATEGORY=disks
# This loop is where the missing-tool bug did its loudest damage: with smartctl absent,
# the old condition simply found no "PASSED" in an empty string and declared every
# healthy disk dead — four screaming FAILs a night about hardware nothing had looked
# at. Hence both the `require` above the loop and the separation below between "the
# drive reports a failure" and "smartctl could not tell us", which are not the same
# news and must not print the same line.
# EVERY physical disk, enumerated from lsblk — not a `/dev/nvme?n1` glob. That glob was
# the check's second, quieter defect: on pve1 the `apps` pool, which holds the system disk
# of every guest in the cluster, lives on **sdb**, a SATA Samsung. It was never once looked
# at. The glob also stops at nvme9 and would miss `/dev/nvme10n1` on the next machine. A
# health check that silently chooses which disks to care about is worth very little; if a
# disk is attached, it gets asked.
if require smartctl "disks"; then
    # lsblk calls a ZFS zvol a "disk" too, and every guest volume shows up as zd0, zd16,
    # zd32… smartctl cannot read those and answers with no verdict at all, which under the
    # rule above is a FAIL — so enumerating on TYPE alone traded one false-alarm storm for
    # another, this time ten lines long. /sys/block/<name>/device exists only for a device
    # backed by real hardware; zvols, device-mapper targets and loop devices have no such
    # link. That is the discriminator, and it needs no allow-list to maintain.
    DISKS=$(lsblk -dn -o NAME,TYPE 2>/dev/null | awk '$2 == "disk" {print $1}')
    if [ -z "$DISKS" ]; then
        fail "disks: could not enumerate block devices (lsblk) — no disk was checked at all"
    fi
    for name in $DISKS; do
        [ -e "/sys/block/$name/device" ] || continue    # zvol / dm / loop — not hardware
        dev="/dev/$name"
        [ -e "$dev" ] || continue
        SMART_OUT=$(smartctl -H "$dev" 2>&1)
        if echo "$SMART_OUT" | grep -qiE 'self-assessment test result: *(PASSED|OK)'; then
            # NVMe reports "Percentage Used" directly. SATA SSDs instead expose a normalised
            # attribute that counts DOWN from 100, so it is inverted here; a spinning disk
            # has neither and simply reports no wear figure, which is correct rather than a
            # gap — endurance is not the thing that kills those.
            WEAR=$(smartctl -A "$dev" 2>/dev/null | awk -F: '/Percentage Used/ {gsub(/[ %]/, "", $2); print $2; exit}')
            if [ -z "$WEAR" ]; then
                WEAR=$(smartctl -A "$dev" 2>/dev/null | awk '
                    /Wear_Leveling_Count|Percent_Lifetime_Remain|SSD_Life_Left|Media_Wearout_Indicator/ {
                        print 100 - $4; exit }')
            fi
            if [ -n "$WEAR" ] && [ "$WEAR" -ge "$NVME_WEAR_WARN" ] 2>/dev/null; then
                warn "disk: $dev at ${WEAR}% endurance used — plan a replacement (Stage 19)"
            else
                ok "disk: $dev healthy${WEAR:+ (${WEAR}% endurance used)}"
            fi
        elif echo "$SMART_OUT" | grep -qiE 'self-assessment test result'; then
            fail "disk: $dev SMART health check FAILED — the drive is reporting a problem, run smartctl -a $dev now (Stage 19)"
        else
            fail "disk: $dev — smartctl returned no health verdict, so this disk is UNKNOWN, not healthy: $(echo "$SMART_OUT" | grep -vE '^[[:space:]]*$' | head -1)"
        fi
    done
fi

# ── Power (node-aware) ────────────────────────────────────────────────────────
CHECK_ID=power CHECK_CATEGORY=host
# MODE decides whether NUT is meant to run at all. On this build it is `none` —
# the UPS has no data path to pve1 (4.6) — while `upsc` stays installed with
# nothing to answer it. A nightly warning nobody can act on is how the real ones
# get skimmed past, so the intended state reports OK and says why.
NUT_MODE=$(awk -F= '/^[[:space:]]*MODE=/ {gsub(/[" ]/, "", $2); print $2}' /etc/nut/nut.conf 2>/dev/null)
if [ "$NUT_MODE" = "none" ]; then
    CHECK_OBSERVATION=notApplicable ok "power: UPS not monitored by design — NUT disabled, no data cable (4.6)"
elif [ -n "$NUT_MODE" ] && command -v upsc >/dev/null 2>&1; then
    UPS_STATUS=$(upsc ups@localhost ups.status 2>/dev/null)
    case "$UPS_STATUS" in
        OL*)  ok "power: UPS on line power" ;;
        OB*)  warn "power: RUNNING ON UPS BATTERY — an outage is in progress (4.4 timeline applies)" ;;
        "")   warn "power: NUT enabled but not answering — the UPS safety net is offline (Stage 4)" ;;
        *)    warn "power: UPS status '$UPS_STATUS'" ;;
    esac
fi
for ac in /sys/class/power_supply/AC*/online; do
    [ -e "$ac" ] || continue
    if [ "$(cat "$ac")" = "0" ]; then
        warn "power: laptop is ON BATTERY — clean shutdown at 10% (Stage 3.2)"
    else
        ok "power: laptop on AC"
    fi
done

# Additional read-only metrics use structured command output and preserve unknown observations.
CHECK_ID=host-metrics CHECK_CATEGORY=monitoring
metrics_script="$(dirname "${BASH_SOURCE[0]}")/infra-host-metrics.py"
if require python3 "host-metrics"; then
    python3 "$metrics_script" "$@"
    metrics_rc=$?
    if [ "$metrics_rc" -gt 2 ]; then
        fail "host-metrics: collector failed (exit $metrics_rc)"
    elif [ "$metrics_rc" -gt "$RC" ]; then
        RC=$metrics_rc
    fi
fi
[ -z "${INFRA_CHECKS_FILE:-}" ] || printf '@complete\n' >> "$INFRA_CHECKS_FILE"
exit "$RC"
