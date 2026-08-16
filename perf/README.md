# Load drills — sizing the connection budget

*Part of [portable-dotnet-architecture](../README.md). Applies to the [`native/`](../native/) and [`docker/`](../docker/) setups.*

A drill answers one question before a release: **does the connection budget hold under real traffic, including while you deploy?** It is deliberately narrow. It is not a benchmark, it does not report a throughput number to put in a slide, and it will refuse to run rather than produce a figure that measures the wrong thing.

```bash
./load-drill.sh up                                            # isolated Postgres
./load-drill.sh steady         --base-url http://10.0.0.5:5000 \
                               --inventory ~/app-inventory/group_vars/all/main.yml
./load-drill.sh deploy-overlap --base-url http://10.0.0.5:5000 \
                               --deploy-cmd "ssh app 'sudo /opt/apps/deploy.sh api.example.com'"
./load-drill.sh down
```

Exit code `0` passes, `1` failed a threshold, `2` refused to start.

## The thing most connection tests get wrong

Under load you will not see `FATAL: sorry, too many clients already`. You will see Npgsql's `The connection pool has been exhausted`, long before Postgres notices anything. There are two ceilings, they fail identically from the outside, and they have opposite fixes:

| | Symptom in `pg_stat_activity` | Fix |
|---|---|---|
| **Pool ceiling** (app-side) | Connections pinned *flat* at `Maximum Pool Size`, most of them `idle`, Postgres bored | A faster query, or a larger pool — **not** more `max_connections` |
| **Server ceiling** (Postgres) | `active` climbing, waits appearing, connections refused | More `max_connections`, or fewer/smaller pools |

Raising `max_connections` against a pool ceiling changes nothing while looking like action. That is why the drill samples the database rather than trusting the HTTP client: latency alone cannot tell the two apart, and the CSV can.

The good news is that a small pool is usually right. At 5 ms per query and three queries per request, 18 connections carry roughly 1200 req/s — which is why a pool of 64 is headroom for a burst, not a throughput setting, and why raising it is never the first thing to try. The drill's job is to confirm queries *stay* short under pressure — not to count connections.

## The window that actually sizes `max_connections`

Steady state is not where the budget is tight. A blue/green deploy is:

```
steady    = instances x (64 + 16 + 2)         two apps -> 164
draining  = steady x 2                        both slots alive -> 328
usable    = max_connections - superuser_reserved_connections   400 - 3 -> 397
```

For the length of `drain_seconds` both slots hold their own Npgsql pools, so the budget doubles — and the ~69 remaining slots are shared with `pg_dump`, `psql` and monitoring. **A third application takes the same arithmetic to 492 and over the edge.**

Two guards that look like they cover an overflow and do not: `superuser_reserved_connections` and `ALTER DATABASE ... CONNECTION LIMIT` are both unenforced for superusers. While the applications connect as `postgres`, one of them can take every slot on the server, starve the other, and lock the operator out of the database it saturated. The line above still sizes the budget correctly — it just does not protect it.

That is the whole reason `deploy-overlap` exists, and why it is the scenario to run before a major change. `steady` cannot observe this window; it projects it arithmetically and warns.

## Two environments

Both matter, for different questions.

| | `docker compose` (here) | Cloned production VM |
|---|---|---|
| Answers | "did this change make it worse?" | "is it ready for production?" |
| Cost | seconds | ~20 minutes |
| Fidelity | same major, same tuning, different CPU/RAM/network | the real thing |
| Cadence | every meaningful change, CI | before a major upgrade or a new application |

The compose environment mirrors the Ansible role's `conf.d` layout, so [`postgres/conf.d/10-tuning.conf`](postgres/conf.d/10-tuning.conf) is the only file that differs from a real host — and `--inventory` cross-checks the one value that matters (`max_connections`), refusing to run on a mismatch.

For the VM clone, the procedure already exists: [`proxmox-lab/operations/20-upgrades.md`](../proxmox-lab/operations/20-upgrades.md) clones VM 1022 onto a spare IP. Point `PGHOST` at the clone and skip `load-drill.sh up` entirely. Use the clone's *own* rendered `10-tuning.conf` — its RAM-derived values are the real ones.

## Restoring data

A drill against an empty database measures nothing. Drop a dump in `dumps/` (it is mounted inside the container) and restore before the run:

```bash
docker compose exec -T postgres createdb -U postgres waa_ro_app
docker compose exec -T postgres pg_restore -U postgres -d waa_ro_app --no-owner /dumps/waa_ro_app.dump
```

The nightly logical dump the `postgres` role writes is exactly the right input. **Anonymise it if the drill box is not as protected as production** — a copy of the production database is production data wherever it lives.

## Configuring it for your application

The harness knows nothing about any specific app. Everything app-shaped is in [`scenarios/endpoints.json`](scenarios/endpoints.json): the traffic mix and weights, the pool sizes per connection string, the deployment shape, and the fixture queries that spread load across real rows instead of hammering one.

Two entries there are easy to overlook and both invalidate a run if wrong:

- **`pools`** — must mirror the `Maximum Pool Size` values in the app's actual connection strings. This is what the verdict compares against to distinguish a pool ceiling from a server ceiling.
- **`clientIp`** — the header the app trusts for client identity. Rate limiting partitions by client IP; the public policy is 64 requests/minute. Without per-VU IPs the entire load collapses into one partition and the drill measures the limiter at about 1 req/s — passing every latency threshold while proving nothing. A single `429` aborts the run and voids the result, on purpose.

## Reading the verdict

```
  peak client connections   58
  usable slots              397  (max_connections 400 - 3 reserved)
[ OK ] peak used 14% of usable slots.
  blue/green worst case     328  (82 per instance x 2 instances x 2 slots during drain)
[ OK ] a deploy under load fits: 328/397 slots.
[WARN] 'waa_ro_app' sat at its pool ceiling (64) for 47/180 samples — requests were queueing for a
       connection. Postgres was not the limit; the fix is a faster query or a larger pool.
```

Each run writes to `runs/<scenario>-<timestamp>/`: `pg-sample.csv` (tidy, one row per database/state/second), `k6-summary.json`, `k6.log`, and `deploy.log` for overlap runs. Keep the ones from before and after a major upgrade — the pair is the evidence, either one alone is an anecdote.

When a run warns about a pool ceiling, `pg_stat_statements` names the query that held it. It is preloaded on the drill box and, since the `postgres` role started setting `shared_preload_libraries`, on the real host too — so the drill and the incident are read with the same query:

```sql
SELECT calls, round(mean_exec_time::numeric, 2) AS avg_ms,
       round(total_exec_time::numeric) AS total_ms, query
FROM pg_stat_statements ORDER BY total_exec_time DESC LIMIT 20;
```

## Connection-string settings worth fixing first

Four defaults bite under load, and a drill will surface all four the hard way. The inventory examples now set all of them; a connection string built anywhere else still has to:

| Setting | Default | Why it matters under load |
|---|---|---|
| `Maximum Pool Size` | **100** | Omitted from a connection string, one app instance can claim 300 slots across three databases — over twice its share. Every template and every environment must set it explicitly. |
| `Timeout` | 15s | A saturated pool holds each request for 15 seconds before failing, filling the Kestrel thread pool and turning a slowdown into an outage. `Timeout=5` fails fast and visibly. |
| `Command Timeout` | 30s | One pathological query holds a connection for half a minute. |
| `Connection Idle Lifetime` | 300s | The pool stays at its high-water mark for five minutes after a burst. A deploy that lands in that window has both slots holding full pools at once — the worst case above stops being theoretical. `60` returns the slots first. |

## What this deliberately does not do

- **No app code changes.** Pool saturation is observable from the server, so nothing needs instrumenting to run a drill. If you later want the exact queue depth, Npgsql 8+ publishes `db.client.connections.*` through `System.Diagnostics.Metrics` — a `MeterListener` behind a flag is enough, and the CSV stops being an inference.
- **No write-path load by default.** Writes touch payment providers, email and SMS. Add them to `traffic` when the drill box is fully isolated, and never point a drill at an environment whose outbound integrations are live.
- **No unattended mode.** Like [`restore-drill`](../proxmox-lab/scripts/restore-drill.sh), this creates load and runs deploys — procedures that deserve someone watching.
