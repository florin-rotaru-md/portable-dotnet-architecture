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
            preAllocatedVUs: 2,
            exec: 'probe',
        },
    },
    thresholds: {
        ...baseThresholds(p95),
        // The whole promise of blue/green, expressed as a gate.
        'drill_dropped_requests': ['count==0'],
        'checks': ['rate>0.99'],
    },
    discardResponseBodies: true,
};

export default function () {
    const res = fireOne();
    // Connection-level failure (status 0) during a swap is a dropped request,
    // not a slow one — the distinction the drain is supposed to make impossible.
    if (res.status === 0) droppedDuringDeploy.add(1);
    sleep(Math.random() * 0.9 + 0.1);
}

export function probe() {
    const path = (config.health && config.health.ready) || '/.well-known/ready';
    const res = http.get(BASE_URL + path, { headers: headers(), tags: { endpoint: 'ready' } });
    if (res.status === 0 || res.status >= 500) droppedDuringDeploy.add(1);
}

export function handleSummary(data) {
    return writeSummary(data);
}
