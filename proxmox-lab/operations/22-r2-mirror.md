# Stage 22 — R2 mirror: operating it

*Part of the [Proxmox lab guide](../README.md). Setup lives in
[17.10](../backup/17-backup-restore.md#1710-a-fifth-tier-for-the-r2-media-bucket); this page is
what you need once it runs: how the pieces move, how to prove it works, and what to do when
something goes wrong.*

## 22.1 How it works

The app writes media — user uploads, generated products, published event snapshots — to the
Cloudflare R2 bucket and **nowhere else**. The mirror is the only copy outside Cloudflare:

```
app → R2 (statics-waa)                                the only writer, the only primary
        │  03:30  r2-backup (pve1):  rclone sync r2:statics-waa → /mnt/usb-backup/r2/statics-waa
        │         deletions/overwrites → /mnt/usb-backup/r2/.trash/statics-waa/<date>/  (kept 30 days)
        ▼
USB drive ── 04:00 rclone sync of the whole drive ──► digi-crypt: (offsite, encrypted)
```

- **The stored remote (`r2:`) is read-only.** A compromise of pve1 can read media, never delete
  it. Anything that writes back to the bucket uses a token minted for the occasion (22.3).
- **Deletions propagate through the trash.** `rclone sync` mirrors them (erasure requests must
  reach the backups too), but every deleted or overwritten object is first *moved* — same
  filesystem, no extra space — into the dated trash dir. A mass-delete is recoverable for 30
  days; a lawful erasure ages out of every copy on its own: mirror the next night, trash ≤ 30
  days, offsite follows the drive at the next 04:00 sync.
- **Log:** `/var/log/rclone-r2.log`. **Watchdog:** `backup-verify` (07:30 cron, mails root)
  checks the log is fresh and error-free — the `r2-mirror:` line.
- **RPO is 24 h**: an object uploaded today exists only in R2 until tonight's run. **RTO is
  minutes** — the mirror is a local disk.
- **What survives without the mirror:** published snapshots (republish the event) and product
  renders (re-download) are regenerable. **User uploads are not** — they are what this tier is
  for.

## 22.2 Proving it works

| When | What | Pass looks like |
|---|---|---|
| Daily, automatic | `backup-verify` → `r2-mirror:` line | `[ OK ] r2-mirror: synced within Nh, no recent errors` — anything else mails root |
| On demand | `r2-backup` by hand, then `tail /var/log/rclone-r2.log` | exit 0, log ends in a transfer summary without `ERROR` |
| On demand, thorough | `rclone check r2:statics-waa /mnt/usb-backup/r2/statics-waa --one-way --fast-list` | `0 differences found` — listings only, reads no object bodies |
| Quarterly (with the [17.9](../backup/17-backup-restore.md#179-restore-drills) drill) | open one mirrored image; pull one object from `digi-crypt:r2/…` and open that too | the image renders — that proves R2 → USB → offsite → eye, crypt passwords included |
| After any change | token rotated, remote reconfigured, bucket renamed | the on-demand pair above |

## 22.3 Incidents

**First, always:** `tail -30 /var/log/rclone-r2.log` and the `r2-mirror:` line of
`backup-verify`. Then find your row:

| Symptom / event | What it means | Do |
|---|---|---|
| `[FAIL] r2-mirror: log untouched…` | the 03:30 cron stopped | `grep r2 /etc/cron.d/pve-helper-scripts`; re-run `install-scripts.sh` if missing; run `r2-backup` by hand and read the error |
| Log shows `401`/`403`/`SignatureDoesNotMatch` | the read-only token was rotated or revoked | mint a new **Object Read only** token (17.10 step 1), `rclone config update r2 access_key_id … secret_access_key …`, re-run |
| Log shows `NoSuchBucket` | bucket renamed or deleted | if renamed: update `BUCKETS` in `r2-backup.sh` and redeploy via `install-scripts.sh`. If deleted: that is the disaster row below |
| One object deleted/overwritten by mistake | it is still in the mirror (if older than last night) or in `.trash/statics-waa/<date>/` (same relative path) | copy it back with a throwaway write token — see *Writing back*, below |
| Mass delete in R2 (retention bug, operator error) | tonight's sync will *move* the mirror copies into today's trash dir — nothing is lost for 30 days, whether it ran or not | stop the cause first (app side: Admin → Retention → `enabled=false` / `dryRun=true` — platform `docs/OPERATIONS.md` §4). Then copy back from the mirror and/or `.trash/<date>/`, in bulk |
| Bucket gone / account compromised | the mirror is now the primary | recreate the bucket, `rclone copy /mnt/usb-backup/r2/statics-waa r2rw:statics-waa`, republish events (refreshes snapshots), rotate the **app's** R2 keys (platform `CREDENTIAL-ROTATION-TODO.md`) *and* this tier's read token |
| USB drive dead/lost | nothing user-facing broke — R2 is still primary | replace per [17.2](../backup/17-backup-restore.md#172-backup-storage--the-usb-drive); the next 03:30 rebuilds the mirror in full; until then yesterday's copy is on `digi-crypt:r2/…` |
| Mirror token leaked | read-only: blast radius is *reading* media | revoke it in the R2 dashboard, mint a new one, `rclone config update` — no object was writable |
| "Erase user X faster than the windows" | the automatic path clears everything in ≤ 31 days | delete the user's prefix by hand from `/mnt/usb-backup/r2/…` **and** `.trash/…`; the 04:00 sync propagates the removal offsite the same night |

**Writing back** (single object or bulk — the stored remote deliberately cannot):

```bash
# 1. Mint a write-capable token in the R2 dashboard (Object Read & Write, this bucket only)
rclone config                       # n → name: r2rw → same endpoint, the new keys

# 2. Copy back — paths under the mirror and under .trash/<date>/ are the bucket's own layout
rclone copy /mnt/usb-backup/r2/statics-waa/ro/users/<uid>/images/<file> r2rw:statics-waa/ro/users/<uid>/images/
# bulk, e.g. everything the 2026-08-12 sweep removed:
rclone copy /mnt/usb-backup/r2/.trash/statics-waa/2026-08-12/ r2rw:statics-waa/

# 3. Revoke the token in the dashboard, then delete the remote
rclone config delete r2rw
```

The app addresses objects by stable paths (`{root}/events/{uid}/…`, `{root}/users/{uid}/…`), so a
copied-back object is served immediately — no database work. The exception is a *published
snapshot* you had no copy of: republishing the event regenerates it.
