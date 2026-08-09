// Shared harness for the drill scenarios. Everything app-specific is read from
// endpoints.json — this file only knows how to weight a request list, give each
// VU its own client identity, and separate "the app failed" from "the drill was
// invalid", which are very different verdicts and easy to confuse.

import http from 'k6/http';
import { Counter, Rate, Trend } from 'k6/metrics';
import { SharedArray } from 'k6/data';

const CONFIG_PATH = __ENV.ENDPOINTS || './endpoints.json';
const FIXTURES_PATH = __ENV.FIXTURES || './.fixtures.json';

// open() is init-context only; SharedArray keeps one copy across all VUs
// instead of one per VU, which at 400 VUs is the difference between a few MB
// and a few hundred.
export const config = JSON.parse(open(CONFIG_PATH));

const fixtures = new SharedArray('fixtures', () => {
    try {
        return [JSON.parse(open(FIXTURES_PATH))];
    } catch (e) {
        // Running without load-drill.sh (hand-invoked k6): scenarios that need
        // a fixture will say so loudly rather than silently request "${slugs}".
        return [{}];
    }
});

export const BASE_URL = (__ENV.BASE_URL || 'http://127.0.0.1:5000').replace(/\/$/, '');

// ── Metrics ───────────────────────────────────────────────────────────────────
// Split deliberately. `rate_limited` and `app_errors` both show up as failures
// in a naive test, but one means "your limiter is doing its job and this drill
// proved nothing", the other means "the app broke under load".
export const rateLimited = new Counter('drill_rate_limited');
export const appErrors = new Counter('drill_app_errors');
export const unexpectedStatus = new Counter('drill_unexpected_status');
export const okRate = new Rate('drill_ok');
export const byEndpoint = new Trend('drill_endpoint_duration', true);

// ── Weighted endpoint pick ────────────────────────────────────────────────────
const traffic = config.traffic || [];
const totalWeight = traffic.reduce((sum, e) => sum + (e.weight || 1), 0);

function pickEndpoint(rnd) {
    let target = rnd * totalWeight;
    for (const endpoint of traffic) {
        target -= endpoint.weight || 1;
        if (target <= 0) return endpoint;
    }
    return traffic[traffic.length - 1];
}

// ── Client identity ───────────────────────────────────────────────────────────
// Each VU presents a distinct client IP. Without this every request lands in
// one rate-limit partition (the 'public' policy is 64/min per IP) and the drill
// measures the limiter instead of the database — about 1 req/s, which passes
// every latency threshold while proving nothing at all.
function clientIp(vu) {
    const base = (config.clientIp && config.clientIp.cidrBase) || '10.99';
    const third = 1 + (Math.floor(vu / 254) % 254);
    const fourth = 1 + (vu % 254);
    return `${base}.${third}.${fourth}`;
}

export function headers() {
    const name = (config.clientIp && config.clientIp.header) || 'CF-Connecting-IP';
    const h = { 'Accept': 'application/json', 'User-Agent': 'k6-load-drill' };
    h[name] = clientIp(__VU);
    return h;
}

// ── Path templating ───────────────────────────────────────────────────────────
// "${slugs}" is replaced by a random member of the 'slugs' fixture list.
function resolvePath(path, rnd) {
    return path.replace(/\$\{(\w+)\}/g, (_, name) => {
        const values = fixtures[0][name];
        if (!values || values.length === 0) {
            throw new Error(
                `Fixture '${name}' is empty — run through load-drill.sh, which fills it from the ` +
                `database, or remove the endpoint that uses it from endpoints.json.`);
        }
        return values[Math.floor(rnd * values.length) % values.length];
    });
}

// ── One request ───────────────────────────────────────────────────────────────
export function fireOne() {
    const rnd = Math.random();
    const endpoint = pickEndpoint(rnd);
    const url = BASE_URL + resolvePath(endpoint.path, Math.random());

    const res = http.request(endpoint.method || 'GET', url, endpoint.body || null, {
        headers: headers(),
        tags: { endpoint: endpoint.name },
    });

    byEndpoint.add(res.timings.duration, { endpoint: endpoint.name });

    if (res.status === 429) {
        // Not an app failure. It means the drill's client-IP spreading did not
        // take, so the numbers below it are meaningless.
        rateLimited.add(1, { endpoint: endpoint.name });
        okRate.add(false);
        return res;
    }

    if (res.status >= 500) {
        appErrors.add(1, { endpoint: endpoint.name });
        okRate.add(false);
        return res;
    }

    const expected = endpoint.expect || [200];
    const ok = expected.includes(res.status);
    if (!ok) unexpectedStatus.add(1, { endpoint: endpoint.name });
    okRate.add(ok);
    return res;
}

// ── Thresholds shared by every scenario ───────────────────────────────────────
// k6 exits non-zero when a threshold breaks, which is what makes this usable as
// a gate rather than a graph someone has to interpret.
export function baseThresholds(p95Ms) {
    return {
        // A single 429 invalidates the run. abortOnFail stops early instead of
        // burning ten minutes producing a number nobody may trust.
        'drill_rate_limited': [{ threshold: 'count==0', abortOnFail: true }],
        'drill_app_errors': ['count==0'],
        'drill_ok': ['rate>0.99'],
        'http_req_duration': [`p(95)<${p95Ms || 500}`],
        'http_req_failed': ['rate<0.01'],
    };
}

// Written next to the run's other artifacts; load-drill.sh reads it for the verdict.
export function writeSummary(data) {
    const out = __ENV.SUMMARY_OUT || './k6-summary.json';
    const result = {};
    result[out] = JSON.stringify(data, null, 2);
    result['stdout'] = textSummary(data);
    return result;
}

// k6's own summary renderer is not importable without the network, so this is a
// deliberately small stand-in: the verdict comes from load-drill.sh anyway.
function textSummary(data) {
    const m = data.metrics || {};
    const line = (label, value) => `  ${label.padEnd(28)} ${value}\n`;
    const val = (metric, field) =>
        m[metric] && m[metric].values && m[metric].values[field] !== undefined
            ? Math.round(m[metric].values[field] * 100) / 100
            : 'n/a';

    return '\n' +
        line('requests', val('http_reqs', 'count')) +
        line('req/s', val('http_reqs', 'rate')) +
        line('duration p95 (ms)', val('http_req_duration', 'p(95)')) +
        line('duration p99 (ms)', val('http_req_duration', 'p(99)')) +
        line('rate-limited (invalidates)', val('drill_rate_limited', 'count')) +
        line('app errors (5xx)', val('drill_app_errors', 'count')) +
        line('unexpected status', val('drill_unexpected_status', 'count')) +
        '\n';
}
