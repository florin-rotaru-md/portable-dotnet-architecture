#!/usr/bin/env bash
# create-vms.sh — Stage 10's four clones as one attended command: clone from
# template 9000, set CPU/RAM, set the static IP, grow the disk, set start-at-boot
# — in the right order (disks are grown BEFORE first boot, so cloud-init's
# growpart finds the final size on its first run).
#
# The table below is the same table as 10-vms.md — if you change one, change
# the other. Idempotent: a VM ID that already exists is skipped, so a re-run
# finishes an interrupted first run without touching what's done.
#
# Run on pve1 (where the template lives). Creates only — starting the VMs is
# offered at the end, separately.
#
# Usage: create-vms

set -euo pipefail

TEMPLATE=9000
GATEWAY=192.168.0.1

# VMID  NAME               STORAGE  CORES  RAM_MB  DISK(- = as cloned)  IP  BOOT(- = stays off)
VMS="\
1020  control-ubuntu     apps  2  4096   -     192.168.0.20  -
1021  app-ubuntu         apps  8  8192   128G  192.168.0.21  order=2
1022  postgres-ubuntu    db    8  32768  640G  192.168.0.22  order=1,up=60
1023  monitoring-ubuntu  apps  2  4096   320G  192.168.0.23  order=3"

ok()      { printf '[ OK ] %s\n' "$1"; }
skip()    { printf '[SKIP] %s\n' "$1"; }
confirm() { read -r -p "$1 [y/N] " a </dev/tty; [ "$a" = "y" ] || [ "$a" = "Y" ]; }

# ── Preconditions ─────────────────────────────────────────────────────────────
if ! qm config "$TEMPLATE" 2>/dev/null | grep -q '^template: 1'; then
    echo "[STOP] VM $TEMPLATE is not a template on this node — build it first (Stage 9), or run this on the node that has it." >&2
    exit 2
fi
for storage in apps db; do
    pvesm status --storage "$storage" >/dev/null 2>&1 \
        || { echo "[STOP] storage '$storage' not available here (Stage 6)." >&2; exit 2; }
done

# The table's addresses assume this node's LAN is the same /24. Get that wrong
# and the VMs boot onto a subnet nobody routes — silently, because the Cloud-Init
# tab keeps showing the address you asked for (10-vms.md, "First boot").
node_cidr=$(ip -4 -o addr show dev vmbr0 2>/dev/null | awk 'NR==1{print $4}') || true
if [ -n "${node_cidr:-}" ] && [ "${node_cidr%.*}" != "${GATEWAY%.*}" ]; then
    echo "[WARN] vmbr0 is ${node_cidr}, but this script assigns ${GATEWAY%.*}.x with gateway ${GATEWAY}."
    echo "       Adapt GATEWAY and the IP column below to your LAN first, or the VMs"
    echo "       come up unreachable. See 10-vms.md, 'First boot'."
    confirm "Continue anyway?" || exit 0
fi

echo "About to create, from template $TEMPLATE:"
echo "$VMS" | awk '{printf "  %s  %-18s %-5s %s cores  %5s MB  disk %-5s %-13s boot %s\n", $1, $2, $3, $4, $5, $6, $7, $8}'
confirm "Proceed?" || exit 0

# ── Create ────────────────────────────────────────────────────────────────────
while read -r id name storage cores ram disk ip boot; do
    [ -n "$id" ] || continue
    if qm status "$id" >/dev/null 2>&1; then
        skip "$id ($name) already exists — leaving it untouched"
        continue
    fi
    qm clone "$TEMPLATE" "$id" --name "$name" --full --storage "$storage" >/dev/null
    qm set "$id" --cores "$cores" --memory "$ram" \
        --ipconfig0 "ip=${ip}/24,gw=${GATEWAY}" >/dev/null
    [ "$disk" != "-" ] && qm resize "$id" scsi0 "$disk"
    # Start at boot: without it a node reboot leaves the VM stopped, and only the
    # two HA VMs would ever come back on their own (10-vms.md, "Start at boot").
    if [ "$boot" = "-" ]; then
        qm set "$id" --onboot 0 >/dev/null
    else
        qm set "$id" --onboot 1 --startup "$boot" >/dev/null
    fi
    ok "$id ($name): ${cores} cores, ${ram} MB, disk ${disk}, ${ip}, boot ${boot}"
done <<< "$VMS"

# CPU type is deliberately NOT touched: clones inherit x86-64-v3 from the
# template, and that is the setting that keeps live migration safe (Stage 9.3).

# ── Start (separately — creation is complete either way) ──────────────────────
if confirm "Start all four now (first boot: cloud-init sets IPs and grows the disks)?"; then
    while read -r id name _; do
        [ -n "$id" ] || continue
        [ "$(qm status "$id" 2>/dev/null)" = "status: stopped" ] && qm start "$id" >/dev/null && ok "$id ($name) started"
    done <<< "$VMS"
    echo
    echo "Give first boot a minute, then check what the GUESTS actually took — the"
    echo "Cloud-Init tab shows what was offered, not what was accepted:"
    echo "    for id in 1020 1021 1022 1023; do qm agent \$id network-get-interfaces; done"
    echo
    echo "Then continue Stage 10 (control node, SSH keys). The clones are key-only from"
    echo "first boot and the seeded key is this node's, so log in from here:"
    echo "    ssh devops@192.168.0.20"
else
    echo "Created, not started. Start them from the UI or: qm start 1020 (etc.)"
fi
