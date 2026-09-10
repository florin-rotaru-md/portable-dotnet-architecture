# Stage 7 — Cluster

*Part of the [Proxmox lab guide](../README.md).*

**On pve1:** Datacenter → Cluster → **Create Cluster** → name `lab`:
- **Link 0** = `192.168.0.11` (the LAN over `vmbr0` — corosync's primary ring, the one that must never be down)
- **Link 1** = `10.10.10.1` (the 10G direct cable — the redundant ring, plugged in on demand)

→ Create → **Join Information → Copy**.

**On pve2:** Datacenter → Cluster → **Join Cluster** → paste the info, pve1's root password:
- **Link 0** = `192.168.0.12`
- **Link 1** = `10.10.10.2`

> **Why the LAN is Link 0 and not the fast cable.** With `link_mode: passive` — what PVE writes, and what this cluster runs — corosync carries membership over one link at a time: the active link with the highest priority, and with no `knet_link_priority` set anywhere (none is), the tie breaks to the lowest link ID. Quorum therefore lands on Link 0, so Link 0 has to be the link that is always plugged in. Here that is the LAN: the 10G's pve2 end is a Thunderbolt dock that is unplugged more often than not ([5.2](../setup/05-network.md#52-the-10g-direct-link--plugged-in-on-demand-not-left-connected)), and with the order reversed every unplug would drag the cluster's membership traffic away with it. This is not something you fix casually afterwards — it means editing `corosync.conf` and bumping `config_version` on a live cluster with the watchdog armed, which is the one edit you least want to be making while a ring is already down.

→ Join. The page will "freeze" (certificates change) — reload the browser.

Verify both rings are up — do it with the 10G cable still connected, because that is the only state in which Link 1 has anything to report ([5.2](../setup/05-network.md#52-the-10g-direct-link--plugged-in-on-demand-not-left-connected)):
```bash
corosync-cfgtool -s     # one block per LINK ID; with the cable in, every peer reads "connected"
corosync-cfgtool -n     # this node's links *toward* each peer: "(192.168.0.11->192.168.0.12) enabled connected"
```

Corosync 3 prints no `status = OK` — that string belongs to corosync 2 and matches nothing on PVE 9. It prints a `status:` block per link with one line per node: `nodeid: 1: localhost` for yourself, `nodeid: 2: connected` or `disconnected` for the peer. Read *both* blocks; a cluster running on a single surviving ring looks entirely healthy at a glance, and that is exactly how ring redundancy gets lost with nobody noticing. Anything you later build on top of this — a grep in a script, an eyeball at 07:00 — must match the failure word `disconnected` and never a success string, because a pattern corosync never emits matches nothing on a dead ring just as cheerfully as on a live one. `-n` is the one output where that rule has nothing to hold on to: a down link there just loses the word `connected` — `LINK: 1 udp (10.10.10.1->10.10.10.2) enabled mtu: 469` is a dead ring, with no failure word anywhere in it — so `-s` is the one to script against.

After the build, `LINK ID 1 … disconnected` is this cluster's **resting** state: the cable goes in for a migration and comes out afterwards, so only Link 0 down is an incident. What that trade costs on the day the switch dies is the table in [5.2](../setup/05-network.md#52-the-10g-direct-link--plugged-in-on-demand-not-left-connected).

**Match links by address, not by number.** The numbering is per-cluster and invisible from the network: `pvecm` gives Link 0 to the address you create and join on unless you pass `link0=` at that moment, so a cluster built in a different order carries the same two rings under swapped IDs — and a replacement node retyped into the join dialog can be numbered backwards with nothing refusing it, which crosses the rings and forms neither ([19.2](../operations/19-node-replacement.md#192-approach-a--clean-swap-step-by-step)). Read the `addr =` line instead — `192.168.0.x` is the ring that carries membership, `10.10.10.x` is the one allowed to be out — which is the same rule the [runbook](../troubleshooting.md#runbook--the-10g-link-is-down) opens with. Trusting the numbering is how you diagnose the healthy ring as the dead one, and the two ends do not even fail alike: pve1's X550 goes `DOWN` with no carrier, pve2's dock disappears from `ip link` entirely (5.2).

`corosync-cfgtool -s` is also a **build-time** check, and for the first week of September nothing took over from it. The nightly [`cluster-health`](../scripts/README.md) reached the verdict `corosync: all links healthy` every morning from 2026-09-05 to 2026-09-10, with the 10G cable out since 09:27 on the 4th: cron ran with `PATH=/usr/bin:/bin`, `corosync-cfgtool` lives in `/usr/sbin`, and the check grepped for `faulty|disconnected` in output that was really `command not found` — **a missing tool reads exactly like a healthy ring**, and it would have read the same way had Link 0 been the one to go. And it reached it silently: the cron entry passes `--quiet`, under which an `[ OK ]` line is not printed at all, so those six mornings produced blank output — the shape of a morning on which everything is fine — and root's mail was being discarded at the recipient in any case ([15.3](../ha/15-ha.md#153-notifications)). `install-scripts.sh` now writes `PATH=/usr/sbin:/usr/bin:/sbin:/bin` into `/etc/cron.d/pve-helper-scripts` and no check passes on a tool it cannot find, but that only reaches a node when [2.4](../setup/02-post-install.md#24-install-the-helper-scripts-both-nodes) is re-run *there*. Until it has been, ring state is something you confirm by hand.

**Migration Settings:** Datacenter → Options → Migration Settings → Network = `192.168.0.0/24`, type `secure` — the management LAN, deliberately *not* the 10G subnet. The cable is plugged in for a migration and unplugged afterwards, so nothing on a schedule is allowed to depend on it being there; the fast path is requested per migration instead, on the `qm migrate` line ([5.4](../setup/05-network.md#54-using-the-10g-link-for-a-migration)).

**Replication Settings:** Datacenter → Options → **Replication Settings** → Network = `192.168.0.0/24`, type `secure`. This is a *second* dialog, not a restatement of the first: since PVE 9, replication reads its own `replication:` key out of `datacenter.cfg` and falls back to `migration:` only when that key is absent. Set one and leave the other, and the two quietly run on different networks — nothing warns you, and the Migration Settings dialog you just filled in still looks correct.

Verify against the file, not the dialogs — each dialog shows you one key, the file shows both:
```bash
grep -E '^(migration|replication):' /etc/pve/datacenter.cfg
```
```
migration: secure,network=192.168.0.0/24
replication: network=192.168.0.0/24,type=secure
```

Two lines, same CIDR, or you have the split above.

Set the bandwidth limit under Datacenter → Options → **Bandwidth Limits** — not the Migration Settings dialog, which carries only type and network — or from a shell: `pvesh set /cluster/options --bwlimit migration=60000` (KiB/s ≈ 60 MB/s). **~60 MB/s** is the number while migration rides the LAN: 1G tops out near 118 MB/s, so this leaves roughly half the wire free. The ~800 MB/s that would suit a dedicated 10G cable is worse than useless here — it never engages, and an uncapped `migration: secure` transfer then saturates the same wire that carries corosync's Link 0, every VM's traffic and every replication job — 1022's runs every minute ([Stage 12](../ha/12-replication.md)). A node that misses its corosync tokens is a node the watchdog fences ([15.4](../ha/15-ha.md#154-the-watchdog--what-fencing-actually-rests-on) / [18.2](../ha/18-failover.md#182-anatomy-of-an-unplanned-failover)) — in the middle of the migration you started.

Three things this key does not do. It does not cap replication: those jobs cross the same wire — three hourly, 1022's every minute — and are limited per job by `rate` (MB/s) in each VM's Replication panel ([Stage 12](../ha/12-replication.md)). It does not know which cable a transfer took, so an on-demand 10G migration ([5.4](../setup/05-network.md#54-using-the-10g-link-for-a-migration)) is throttled by the LAN number too — raise or lift it for that one run with `--bwlimit` on the `qm migrate` line (`0` = unlimited; only a privileged user can exceed the datacenter default, a restricted one can only go lower). And it is not set today: `/etc/pve/datacenter.cfg` carries no `bwlimit` key at all, so the first large migration is the experiment.

> **What losing the 10G link actually costs — and what it does not.** Not migration and not replication. Both read their network out of `datacenter.cfg`, pinned to `192.168.0.0/24` above, so they carry on over the LAN: slower, uninterrupted, and with nothing for you to change — which is the whole reason the pinning stays. What you lose is corosync's *second* ring, and because the QDevice sits on that same LAN, a switch failure while Link 1 is out leaves each node at 1 vote of 3, not quorate, and with fencing armed **both** nodes self-fence ([5.2](../setup/05-network.md#52-the-10g-direct-link--plugged-in-on-demand-not-left-connected) has the arithmetic). That state is silent by construction — a cluster on one surviving ring looks identical to a healthy one — which is how these two nodes ran single-ringed from **2026-09-04 09:27** for six days before anyone looked. The runbook for the day you decide the cable belongs back in permanently, including the optional single-network variant, is in [troubleshooting](../troubleshooting.md#runbook--the-10g-link-is-down); note that its "repoint migration at the LAN" step is already the standing configuration here, so on this build that runbook is about the cable and the ring, nothing more.
