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
export const transportFailures = new Counter('drill_transport_failures');
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
// one rate-limit partition (RateLimiting:PublicRead is 240/min per IP) and the
// drill measures the limiter instead of the database — 4 req/s, which passes
// every latency threshold while proving nothing at all.
function clientIp(vu) {
    const base = (config.clientIp && config.clientIp.cidrBase) || '10.99';
    const third = 1 + (Math.floor(vu / 254) % 254);
    const fourth = 1 + (vu % 254);
    return `${base}.${third}.${fourth}`;
}

// ── Static headers ────────────────────────────────────────────────────────────
// The client IP above is an identity the drill invents. This is the other kind:
// a header the host requires before it will answer at all. FiscalServer refuses
// every route but its two probes and the ANAF callback with a bodiless 401
// unless 'x-api-key' matches, so without a seam like this the drill cannot
// touch it — and a run made entirely of 401s would pass every latency
// threshold while measuring the middleware.
//
// Resolved once, in init context, so a missing credential stops the run before
// it starts rather than at the first request. `${NAME}` reads the environment,
// which is how a real key is passed without landing in endpoints.json.
function resolveHeaders(source, where) {
    const out = {};
    for (const key of Object.keys(source || {})) {
        if (key === '_readme') continue;
        const value = source[key];
        out[key] = typeof value !== 'string' ? value : value.replace(
            /\$\{(\w+)\}/g,
            (_, name) => {
                const fromEnv = __ENV[name];
                if (fromEnv === undefined || fromEnv === '') {
                    throw new Error(
                        `Header '${key}' in ${where} needs ${name} in the environment and it is ` +
                        `unset. Export it before the drill (it is a credential — do not put the ` +
                        `value in endpoints.json), or remove the header.`);
                }
                return fromEnv;
            });
    }
    return out;
}

const staticHeaders = resolveHeaders(config.headers && config.headers.set, 'headers.set');
const endpointHeaders = {};
for (const endpoint of traffic) {
    if (endpoint.headers) {
        endpointHeaders[endpoint.name] = resolveHeaders(
            endpoint.headers, `traffic['${endpoint.name}'].headers`);
    }
}

export function headers(endpoint) {
    const name = (config.clientIp && config.clientIp.header) || 'CF-Connecting-IP';
    const h = { 'Accept': 'application/json', 'User-Agent': 'k6-load-drill' };
    Object.assign(h, staticHeaders);
    if (endpoint && endpointHeaders[endpoint.name]) {
        Object.assign(h, endpointHeaders[endpoint.name]);
    }
    // Last, so a scenario cannot accidentally override the identity the whole
    // rate-limit spreading depends on.
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
        headers: headers(endpoint),
        tags: { endpoint: endpoint.name },
    });

    byEndpoint.add(res.timings.duration, { endpoint: endpoint.name });

    if (res.status === 0) {
        // No HTTP status at all — refused, reset, or k6's own timeout. The app
        // never answered, so this is not an "unexpected status"; it is a
        // transport failure and carries its own name and its own gate. Under
        // steady load it is the only signal for a connection-level failure;
        // during a deploy the scenario counts the same event again as a dropped
        // request, which is a second question about one event, not a double.
        transportFailures.add(1, { endpoint: endpoint.name });
        okRate.add(false);
        return res;
    }

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
        'drill_transport_failures': ['count==0'],
        // A status outside the endpoint's `expect` is zero-tolerance too. The two
        // rate gates below allow 1 %, which in a 200-slug fixture is three stale
        // slugs answering 404 on one round trip each, passing while measuring the
        // cheap path; a Counter at zero is what makes "must fail the run" true.
        'drill_unexpected_status': ['count==0'],
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
        line('transport failures (no status)', val('drill_transport_failures', 'count')) +
        line('unexpected status', val('drill_unexpected_status', 'count')) +
        '\n';
}
