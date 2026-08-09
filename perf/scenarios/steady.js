// Scenario 1 — where does it saturate?
//
// Ramps concurrency until latency degrades, then holds. The question it answers
// is NOT "does Postgres accept 128 connections" (it does) but "at what arrival
// rate do queries stop being short enough for a pool of 18 to carry them".
//
// Read it together with the pg-sample.csv the drill collects alongside: the
// signature of pool saturation is connections pinned flat at Maximum Pool Size
// while latency climbs. Postgres is idle; the app is queueing. Raising
// max_connections would change nothing — the fix is a faster query or a bigger
// pool, and the CSV tells you which.
//
//   VUS_PEAK    top of the ramp (default 200)
//   RAMP        seconds per stage (default 60)
//   P95_MS      latency threshold that defines "still healthy" (default 500)

import { sleep } from 'k6';
import { fireOne, baseThresholds, writeSummary } from './lib.js';

const peak = parseInt(__ENV.VUS_PEAK || '200', 10);
const ramp = `${parseInt(__ENV.RAMP || '60', 10)}s`;
const p95 = parseInt(__ENV.P95_MS || '500', 10);

export const options = {
    scenarios: {
        ramp_to_saturation: {
            executor: 'ramping-vus',
            startVUs: 5,
            // Quarter, half, full, hold, drain. The hold is what matters: a
            // pool problem needs sustained pressure to show, and a ramp that
            // only touches peak for a moment reports the transient, not the
            // steady state.
            stages: [
                { duration: ramp, target: Math.max(5, Math.round(peak * 0.25)) },
                { duration: ramp, target: Math.max(10, Math.round(peak * 0.5)) },
                { duration: ramp, target: peak },
                { duration: `${parseInt(__ENV.RAMP || '60', 10) * 2}s`, target: peak },
                { duration: '20s', target: 0 },
            ],
            gracefulRampDown: '20s',
        },
    },
    thresholds: baseThresholds(p95),
    // Connection reuse matters: without it k6 opens a TCP+TLS handshake per
    // request and measures its own client, not the server.
    noConnectionReuse: false,
    discardResponseBodies: true,
};

export default function () {
    fireOne();
    // A real visitor reads the page. Zero think-time turns a load test into a
    // benchmark of the loopback interface.
    sleep(Math.random() * 0.9 + 0.1);
}

export function handleSummary(data) {
    return writeSummary(data);
}
