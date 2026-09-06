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

Steady state is not where the budget is tight. A blue/green deploy is — and the fleet is not uniform, so the arithmetic is per deployment, not one number times an instance count:

| deployment | App | Users | DataProtection | per instance |
|---|---|---|---|---|
| `api.waa.ro` | 64 | 16 | 2 | 82 |
| `api.waa.events` | 64 | 16 | 2 | 82 |
| `fiscal` | 16 | — | 2 | **18** (headless: no users database) |
| **steady** | | | | **182** |
| + the largest single drain (one Waa slot) | | | | +82 |
| **worst case, deploys serialised** | | | | **264** |
| usable — `max_connections` 640 less 3 `superuser_reserved_connections` | | | | 637 |
| headroom for `pg_dump`, `psql`, monitoring | | | | 373 |

For the length of `drain_seconds` both slots of the *deploying* application hold their own Npgsql pools, so that one application's footprint doubles. Only one does: `deploy.yml` loops over the applications and `deploy.sh` blocks through the drain. Adding every deployment's drain together instead — 364 here — is a case nobody performs, and the older `82 x 3 apps x 2 slots = 492` was worse still, because it also charged the smallest deployment at the largest one's size. The drill prints both readings; the serialised one decides the verdict.

The numbers' home is the live inventory, above `postgres_max_connections`; the arithmetic is explained once in the application repository (`platform/docs/fiscal/OPERATIONS.md` §1.1), and [`scenarios/endpoints.json`](scenarios/endpoints.json) is the copy this harness computes from. Keep the three in step — nothing enforces it.

**Serialised deploys are an honour system, and stay one.** Every deployment on this cluster connects as `postgres`, a superuser, and owns its own databases — chosen deliberately, for one backup and restore story, with the cost accepted. For a superuser both `superuser_reserved_connections` and `ALTER DATABASE ... CONNECTION LIMIT` are unenforced, so **the hole is open**: one application can take every slot on the server, starve the others, and lock the operator out of the database it saturated. Nothing in the paragraph above is protected by the database; 264 is what a deploy costs when deploys go one at a time, and `deploy.yml` looping is the only reason they do.

What would close it — recorded, not in force — is each deployment connecting as its own non-superuser role with a `CONNECTION LIMIT` equal to its drain-doubled footprint: 164 + 164 + 36 = 364, and 448 once `api.educa.ro` adds its 84 — which with the 3 reserved is 451 of 640, so even simultaneous drains would fit and no application could take a slot belonging to another. **That sum is why the ceiling moved to 640 on 2026-09-03**: at 400 those four caps did not fit under the usable 397, so the roles could not have been installed without cutting a Waa pool first. They still do not exist — the ceiling was raised ahead of them, which means the hole above is for now *wider* (637 slots, not 397), and only closes when the roles land. The table above sizes the budget either way; it is `Maximum Pool Size` in the connection strings — client-side, and therefore actually enforced — that keeps the table true.

`api.educa.ro` is deliberately absent from the sums: it is not deployed, and a paper reservation is how a number stops being checked. At its proposed 32 + 8 + 2 = 42 it takes steady to 224 and the worst case to 306 of 637. Add its row when it is deployed, and set `deployment.deployments` in [`scenarios/endpoints.json`](scenarios/endpoints.json) in the same edit — the drill computes the fleet from there, not from this table.

That window is the whole reason `deploy-overlap` exists, and why it is the scenario to run before a major change. `steady` cannot observe it; it projects it arithmetically and warns.

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

Two things about that dump, both learnt on 2026-09-06:

- **Before launch there may be nothing in it worth drilling.** A pre-launch `waa_ro_app` held zero events; the fixture query then fills nothing and the pre-flight refuses. The answer is not a synthetic corpus — see *What the observed peak can and cannot show* below for why row count is not what binds — but one or two **genuinely published** events made through the console, dumped fresh. Two were enough for the harness to run end to end and for every read in the mix to answer 200.
- **The nightly dump can be older than the binary.** It is taken at `postgres_backup_hour:postgres_backup_minute` from the live inventory — 05:15 today; a deploy later the same morning can carry a migration the dump's schema predates. The application then aborts at boot against the restored copy — `42P07: relation "…" already exists` when a squashed `Init` meets a schema that already has its objects. Compare `__EFMigrationsHistory` in the dump with the slot you are about to run, or take `pg_dump` fresh from production rather than from `backups/`.

`--no-owner` belongs here and only here. The nightly dumps carry ownership and grants, because a restore that drops them hands the application a database it cannot write to; the drill box has none of the production roles, so it takes the data and leaves the ownership behind. A restore that is meant to *replace* production must not pass it — see the drill in [`native/example`](../native/example).

## Configuring it for your application

The harness knows nothing about any specific app. Everything app-shaped is in [`scenarios/endpoints.json`](scenarios/endpoints.json): the traffic mix and weights, the pool sizes per connection string, the fleet the database is shared with, and the fixture queries that spread load across real rows instead of hammering one.

Four entries there are easy to overlook, and three of them invalidate a run if wrong:

- **`pools`** — the application *under test*: must mirror the `Maximum Pool Size` values in its actual connection strings. This is what the verdict compares against to distinguish a pool ceiling from a server ceiling, and its `app.database` is the drill's `PGDATABASE`.
- **`deployment.deployments`** — every application sharing the production Postgres, each with its own pool set. This is the budget half, and it is separate from `pools` because the fleet is not on the drill box. A config that omits it falls back to `deployment.instances` copies of the app under test — the old uniform model, which is a guess.
- **`clientIp`** — the header the app trusts for client identity. Rate limiting partitions by client IP; the public-read policy (`RateLimiting:PublicRead`) is 240 requests/minute. Without per-VU IPs the entire load collapses into one partition and the drill measures the limiter at 4 req/s — passing every latency threshold while proving nothing. A single `429` aborts the run and voids the result, on purpose.
- **`headers.set`** — static headers sent with every request, for a host that will not answer without a credential. FiscalServer is the case: every route but `/.well-known/ready`, `/.well-known/live` and the ANAF callback answers a bodiless `401` without a valid `x-api-key`. A value written `${NAME}` is read from the environment at k6 init and the run refuses to start when it is unset, so the key is exported, never committed. An entry in `traffic` may carry its own `headers` object, merged over these. **It ships empty**: FiscalServer is inert, and which of its routes are worth loading is an operator's choice — the seam is here, the traffic mix is not.

## Reading the verdict

```
  peak client connections   66
  usable slots              637  (max_connections 640 - 3 reserved)
[ OK ] peak used 10% of usable slots.
  deployment pool cap       82  (sum of pools.*, one slot — the observed peak cannot exceed it on a one-deployment box)
  fleet steady total        182  (api.waa.ro 82 + api.waa.events 82 + fiscal 18)
  blue/green worst case     264  (182 steady + 82 for the largest single drain: api.waa.ro)
[ OK ] a deploy under load fits: 264/637 slots.
[ OK ] simultaneous drains also fit: 364/637 slots — the budget does not rest on deploys being serialised.
[WARN] 'waa_ro_app' sat at its pool ceiling (64) for 47/180 samples — requests were queueing for a
       connection. Postgres was not the limit; the fix is a faster query or a larger pool, and
       pg_stat_statements says which.
```

The two projection lines answer different questions. `blue/green worst case` is what a deploy actually costs and is the one that can fail the run. The line under it is the paranoid reading — every deployment draining at the same moment — reported because it is the number per-deployment `CONNECTION LIMIT`s would have to add up to on the day anyone sets them, and warned about rather than failed, since nothing schedules deploys that way and nothing today enforces that they are not.

Each run writes to `runs/<scenario>-<timestamp>/`: `pg-sample.csv` (tidy, one row per database/state/second), `k6-summary.json`, `k6.log`, and `deploy.log` for overlap runs. Keep the ones from before and after a major upgrade — the pair is the evidence, either one alone is an anecdote.

When a run warns about a pool ceiling, `pg_stat_statements` names the query that held it. It is preloaded on the drill box and, since the `postgres` role started setting `shared_preload_libraries`, on the real host too — so the drill and the incident are read with the same query:

```sql
SELECT calls, round(mean_exec_time::numeric, 2) AS avg_ms,
       round(total_exec_time::numeric) AS total_ms, query
FROM pg_stat_statements ORDER BY total_exec_time DESC LIMIT 20;
```

## What the observed peak can and cannot show

`peak client connections` is a measurement; the two projection lines are arithmetic. It is
tempting to read a low peak as headroom, and on the compose box it is nothing of the kind.

**The generator bounds it before the database does.** Both scenarios are closed-loop: a VU fires a
request, waits for it, sleeps a think time, repeats. By Little's law the *mean* connections in
flight are `VUs × service / (service + think)`. `deploy-overlap` runs 50 VUs with a mean think of
0.55 s; at six milliseconds per request that is a mean of half a connection in flight, and at
200 VUs a mean of about two with a high-water mark near ten — the pool opens a connection per coincident arrival and
keeps it for `Connection Idle Lifetime`, so the per-second maximum the sampler records sits above
the mean. A `steady` run on 2026-09-06 — ramp to 200 VUs, 74 435 requests, p95 5.9 ms, the
connection strings carrying `Connection Idle Lifetime=60` — peaked at **11** against this
deployment's pool sum of 82 (64 of them the app pool) and 637 usable slots. That is 1.7 %
utilisation, not 98 % headroom: it is the generator's own ceiling, and no quantity of seeded rows
moves it. A working set of two events and one of two hundred both sit in `shared_buffers`, and the
per-request cost is a property of one served event, not of how many neighbours it has.

One artefact, since removed but worth knowing: `constant-vus` starts every VU in the same instant,
so the first second of `deploy-overlap` used to open as many connections as there are VUs, which
then sat idle for `Connection Idle Lifetime`. On the first 2026-09-06 overlap run (`--vus 50
--duration 90 --deploy-at 30`) that start burst, not the swap, was the peak: 50, with 47 idle, five
seconds *before* the deploy fired; the restarted process, fed by arrivals that were by then
staggered, opened 14. `deploy-overlap.js` now sleeps a random fraction of a second on each VU's
first iteration, which spreads the start over the same window the think time spreads everything
after it. If a peak ever again sits within one or two of the VU count with the state column reading
idle, that is what you are looking at.

**The box carries one deployment.** Its Npgsql pools cap what it can open — `pools.*` in
`endpoints.json`, 82 for a Waa deployment, and twice that through a `deploy-overlap` drain when both
slots are alive — so the observed peak cannot approach the fleet's 637 on such a box however the
load is shaped. The verdict prints that cap beside the peak for exactly
this reason. The fleet number, 264 for the worst single drain, is only observable where all three
deployments run against one Postgres: the cloned production VM, not compose.

**So what does a run on the compose box prove?** The mechanism, not the magnitude. That the
fixture fills and every read in the mix answers 200; that per-VU client IPs reach the rate limiter
so 200 VUs do not collapse into one partition; that the 40 % config tail really is cached and the
database pressure really does sit in the snapshot read; that `deploy-overlap`'s probe sees a
readiness flap and a dropped request when a swap goes wrong — yes/no facts and durations, all of
which are worth confirming whenever the mechanism changes: a new endpoint in the mix, a
rate-limiter or client-IP change, a change to `deploy.sh`. That is the cadence the *Two
environments* table gives the compose box, and it is not "once". What it cannot prove is that 640 is enough, and a green verdict
must not be filed as if it had. The line that validates 640 is `blue/green worst case` — jq over
the pool sizes you declared against two server GUCs — and it needs no data, no k6 and no run. Record
it as a configuration-consistency result, which is what it is: `Maximum Pool Size` is a declared
client-side ceiling, not a discovered one.

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
