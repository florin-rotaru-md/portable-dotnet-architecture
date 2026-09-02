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
| `fiscal.waa.ro` | 16 | — | 2 | **18** (headless: no users database) |
| **steady** | | | | **182** |
| + the largest single drain (one Waa slot) | | | | +82 |
| **worst case, deploys serialised** | | | | **264** |
| usable — `max_connections` 400 less 3 `superuser_reserved_connections` | | | | 397 |
| headroom for `pg_dump`, `psql`, monitoring | | | | 133 |

For the length of `drain_seconds` both slots of the *deploying* application hold their own Npgsql pools, so that one application's footprint doubles. Only one does: `deploy.yml` loops over the applications and `deploy.sh` blocks through the drain. Adding every deployment's drain together instead — 364 here — is a case nobody performs, and the older `82 x 3 apps x 2 slots = 492` was worse still, because it also charged the smallest deployment at the largest one's size. The drill prints both readings; the serialised one decides the verdict.

The numbers' home is the live inventory, above `postgres_max_connections`; the arithmetic is explained once in the application repository (`statics/docs/fiscal/OPERATIONS.md` §1.1), and [`scenarios/endpoints.json`](scenarios/endpoints.json) is the copy this harness computes from. Keep the three in step — nothing enforces it.

Serialised deploys stop being an honour system once each deployment connects as its own non-superuser role with a `CONNECTION LIMIT` equal to its drain-doubled footprint — 164 + 164 + 36 = 364, which with the 3 reserved is 367 of 400, so even simultaneous drains fit and no application can take a slot that belongs to another. Until those roles exist every application connects as `postgres`, a superuser, for which both `superuser_reserved_connections` and `ALTER DATABASE ... CONNECTION LIMIT` are unenforced: one application can take every slot on the server, starve the others, and lock the operator out of the database it saturated. The table above sizes the budget either way; the roles are what protect it.

`api.educa.ro` is deliberately absent: it is not deployed. At its proposed 32 + 8 + 2 = 42 it takes steady to 224 and the worst case to 306 of 397 — but the sum of caps to 448, over the usable 397. Onboarding it means cutting a Waa pool or raising `max_connections`. Redo the table then.

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

`--no-owner` belongs here and only here. The nightly dumps carry ownership and grants, because a restore that drops them hands the application a database it cannot write to; the drill box has none of the production roles, so it takes the data and leaves the ownership behind. A restore that is meant to *replace* production must not pass it — see the drill in [`native/example`](../native/example).

## Configuring it for your application

The harness knows nothing about any specific app. Everything app-shaped is in [`scenarios/endpoints.json`](scenarios/endpoints.json): the traffic mix and weights, the pool sizes per connection string, the fleet the database is shared with, and the fixture queries that spread load across real rows instead of hammering one.

Four entries there are easy to overlook, and three of them invalidate a run if wrong:

- **`pools`** — the application *under test*: must mirror the `Maximum Pool Size` values in its actual connection strings. This is what the verdict compares against to distinguish a pool ceiling from a server ceiling, and its `app.database` is the drill's `PGDATABASE`.
- **`deployment.deployments`** — every application sharing the production Postgres, each with its own pool set. This is the budget half, and it is separate from `pools` because the fleet is not on the drill box. A config that omits it falls back to `deployment.instances` copies of the app under test — the old uniform model, which is a guess.
- **`clientIp`** — the header the app trusts for client identity. Rate limiting partitions by client IP; the public policy is 64 requests/minute. Without per-VU IPs the entire load collapses into one partition and the drill measures the limiter at about 1 req/s — passing every latency threshold while proving nothing. A single `429` aborts the run and voids the result, on purpose.
- **`headers.set`** — static headers sent with every request, for a host that will not answer without a credential. FiscalServer is the case: every route but `/.well-known/ready`, `/.well-known/live` and the ANAF callback answers a bodiless `401` without a valid `x-api-key`. A value written `${NAME}` is read from the environment at k6 init and the run refuses to start when it is unset, so the key is exported, never committed. An entry in `traffic` may carry its own `headers` object, merged over these. **It ships empty**: FiscalServer is inert, and which of its routes are worth loading is an operator's choice — the seam is here, the traffic mix is not.

## Reading the verdict

```
  peak client connections   58
  usable slots              397  (max_connections 400 - 3 reserved)
[ OK ] peak used 14% of usable slots.
  fleet steady total        182  (api.waa.ro 82 + api.waa.events 82 + fiscal.waa.ro 18)
  blue/green worst case     264  (182 steady + 82 for the largest single drain: api.waa.ro)
[ OK ] a deploy under load fits: 264/397 slots.
[ OK ] simultaneous drains also fit: 364/397 slots — the budget does not rest on deploys being serialised.
[WARN] 'waa_ro_app' sat at its pool ceiling (64) for 47/180 samples — requests were queueing for a
       connection. Postgres was not the limit; the fix is a faster query or a larger pool.
```

The two projection lines answer different questions. `blue/green worst case` is what a deploy actually costs and is the one that can fail the run. The line under it is the paranoid reading — every deployment draining at the same moment — reported because it is what the per-deployment `CONNECTION LIMIT`s have to add up to, and warned about rather than failed, since nothing schedules deploys that way.

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
