// Scenario 2 — the one that actually sizes max_connections.
//
// Steady traffic at a level already known healthy, while a blue/green deploy
// runs underneath it. For the length of the drain BOTH slots of the deploying
// application are alive, each holding its own Npgsql pools, so that one
// application's footprint doubles:
//
//     steady   = sum of every deployment's own per-instance total
//     draining = steady + the largest single deployment   <-- the peak
//                                                             nobody sizes for
//
// The deployments are not the same size — see deployment.deployments in
// endpoints.json — and only one of them drains at a time, because deploy.yml
// loops over the applications and deploy.sh blocks through the drain. The
// budget the whole harness exists to size is that peak, not the steady state,
// which is why this scenario is the gate before a major change and the ramp
// test is not.
//
// This script only generates the load and marks the window. load-drill.sh
// triggers the deploy at DEPLOY_AT seconds and pg-sample.sh records the peak.
//
//   VUS          constant concurrency (default 50 — healthy, not saturating)
//   DURATION     total seconds (default 240)
//   DEPLOY_AT    seconds into the run when the deploy fires (default 90)
//   P95_MS       latency threshold (default 800 — a drain is allowed to hurt)

import { sleep } from 'k6';
import { fireOne, baseThresholds, writeSummary, BASE_URL, headers, config } from './lib.js';
import http from 'k6/http';
import { Counter } from 'k6/metrics';

const vus = parseInt(__ENV.VUS || '50', 10);
const duration = parseInt(__ENV.DURATION || '240', 10);
const p95 = parseInt(__ENV.P95_MS || '800', 10);

// A deploy is allowed to cost latency. It is not allowed to drop a request:
// blue/green plus the drain exists precisely so it doesn't.
const droppedDuringDeploy = new Counter('drill_dropped_requests');

export const options = {
    scenarios: {
        constant_traffic: {
            executor: 'constant-vus',
            vus: vus,
            duration: `${duration}s`,
        },
        // An independent, low-rate health probe. Health endpoints are exempt
        // from rate limiting, so this keeps measuring even if everything else
        // is being refused — and a readiness flap during the swap is exactly
        // the thing a summary of averages would hide.
        readiness_probe: {
            executor: 'constant-arrival-rate',
            rate: 2,
            timeUnit: '1s',
            duration: `${duration}s`,
            // The arithmetic is rate x longest request: with k6's 60 s default timeout
            // a hung swap needs 120 VUs to keep the probe scheduled, and the first
            // version of this fix (maxVUs 20) covered ten seconds of it and then went
            // silent again. So the probe bounds its own request instead — 5 s, in
            // probe() — and a hang becomes a status 0 in drill_dropped_requests within
            // five seconds rather than a held VU. In flight is then at most 2/s x 5 s
            // = 10; twelve pre-allocated covers it without ever asking for an unplanned
            // VU — and the asking matters, because k6 DROPS the tick that triggers an
            // allocation, so a pool that grows from 2 toward maxVUs drops iterations on
            // the way up. Equal pre-allocated and max: no growth, no drop, and the
            // dropped_iterations gate below can be zero-tolerance. Before 2026-09-06
            // this had preAllocatedVUs 2 and no maxVUs at all (k6 caps at
            // preAllocatedVUs by default), so two hung probes silenced it for the rest
            // of the swap, with a warning nobody reads.
            preAllocatedVUs: 12,
            maxVUs: 12,
            exec: 'probe',
        },
    },
    thresholds: {
        ...baseThresholds(p95),
        // The whole promise of blue/green, expressed as a gate. The probe feeds it
        // too — a readiness 5xx, a connection failure or a 5 s timeout during the
        // swap lands here — so there is no separate 'checks' threshold: the harness
        // calls check() nowhere, and a threshold on a metric with no samples passes
        // silently (k6 v2.2.0, verified 2026-09-06: exit 0 on an empty 'checks').
        // That is what the old `'checks': ['rate>0.99']` line did, run after run.
        'drill_dropped_requests': ['count==0'],
        // And the probe must never fall behind: a scheduled probe that found no free
        // VU is a second of the swap nobody looked at. Zero-tolerance, and valid on
        // an empty metric — count==0 passes when nothing was ever dropped.
        'dropped_iterations': ['count==0'],
        // A readiness that answers 200 but slowly — CanConnectAsync queueing for
        // a pooled connection through the drain — is invisible to the two gates
        // above and to the global p95, where the probe is ~2 % of samples. Its
        // own tag gets its own latency gate: readiness answers in single-digit
        // milliseconds, so half a second is already a flap.
        'http_req_duration{endpoint:ready}': ['p(95)<500'],
    },
    discardResponseBodies: true,
};

export default function () {
    // constant-vus starts every VU in the same instant. Without this the first
    // second opens as many connections as there are VUs — the run's peak, seconds
    // before any deploy, 47 of 50 idle on 2026-09-06 — and the verdict reads the
    // generator's start instead of the drain. One random sleep on the first
    // iteration spreads the start over the same 0-1 s window the think time
    // spreads every later request. steady.js needs none: ramping-vus starts small.
    if (__ITER === 0) sleep(Math.random());
    const res = fireOne();
    // Connection-level failure (status 0) during a swap is a dropped request,
    // not a slow one — the distinction the drain is supposed to make impossible.
    // lib.js has already counted the same event as a transport failure; that is
    // a second question about it ("did the deploy drop anything?"), not a double.
    if (res.status === 0) droppedDuringDeploy.add(1);
    sleep(Math.random() * 0.9 + 0.1);
}

export function probe() {
    const path = (config.health && config.health.ready) || '/.well-known/ready';
    // 5 s: a hang is turned into a status 0 within five seconds and counted
    // below, instead of holding the VU for k6's 60 s default. A slow-but-200
    // answer is not caught here; the p95 gate on this tag, in thresholds, is.
    const res = http.get(BASE_URL + path, { headers: headers(), tags: { endpoint: 'ready' }, timeout: '5s' });
    if (res.status === 0 || res.status >= 500) droppedDuringDeploy.add(1);
}

export function handleSummary(data) {
    return writeSummary(data);
}
