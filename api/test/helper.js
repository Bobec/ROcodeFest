'use strict';
// =====================================================================
// Test scaffolding
// =====================================================================
// The same discipline the SQL suites use, in the language the API is
// written in:
//
//   * a fresh state per file, so no test can pass because of something
//     an earlier one left behind
//   * a VACUITY GUARD: a run against a database with no schema would
//     otherwise report every assertion as passing, having tested nothing
//   * every rejection asserts its STATUS, not merely that it failed --
//     "refused for the wrong reason" is the failure the SQL suites keep
//     catching, and HTTP has the same trap
//
// No test framework and no HTTP client beyond what Node ships with.
// node:test and fetch are both built in, so the API's dependency list
// stays at four.
const assert = require('node:assert/strict');
const app = require('../server');
const { pool } = require('../db');

let server, base;

async function start() {
  // Port 0 asks the OS for a free one, so test files never collide with
  // each other or with a development server on 3000.
  server = app.listen(0);
  await new Promise((r) => server.once('listening', r));
  base = `http://127.0.0.1:${server.address().port}`;
  return base;
}

async function stop() {
  if (server) await new Promise((r) => server.close(r));
  await pool.end();
}

// The schema has to actually be there. Without this, a run against an
// empty database would truncate nothing, create nothing, and report a
// green suite that touched no rules at all.
async function assertSchemaPresent() {
  const r = await pool.query(
    `SELECT count(*)::int AS n FROM information_schema.tables
     WHERE table_schema = 'oltp' AND table_type = 'BASE TABLE'`
  );
  assert.ok(
    r.rows[0].n > 30,
    `oltp has ${r.rows[0].n} tables -- load db/01_oltp_schema.sql into ` +
    `${process.env.PGDATABASE || 'rocodefest'} before running these tests`
  );
}

// accounts is the root of every cascade in this schema, so one truncate
// clears clubs, teams, memberships and the rest with it.
//
// This is why the tests run with --test-concurrency=1. node:test runs
// test FILES in parallel by default, and they share one database -- so
// one file's reset would wipe another file's fixture mid-assertion. Run
// in parallel the first time, six tests failed for that reason alone and
// every one of them passed on its own.
async function reset() {
  await assertSchemaPresent();
  await pool.query('TRUNCATE oltp.accounts CASCADE');
}

// ---------------------------------------------------------------------
// A client that remembers its cookies
// ---------------------------------------------------------------------
// fetch has no cookie jar, and the session IS a cookie -- so without
// this, every request would arrive signed out and the authorisation
// tests would pass for entirely the wrong reason.
function client() {
  let cookie = null;
  async function call(method, path, body) {
    const headers = {};
    if (body !== undefined) headers['Content-Type'] = 'application/json';
    if (cookie) headers['Cookie'] = cookie;

    const res = await fetch(base + path, {
      method,
      headers,
      body: body === undefined ? undefined : JSON.stringify(body),
    });

    const set = res.headers.getSetCookie ? res.headers.getSetCookie() : [];
    for (const c of set) {
      const pair = c.split(';')[0];
      // an expired cookie is how logout is delivered; dropping the jar
      // here is what makes "signed out" testable
      if (/=;|=\s*$/.test(pair)) cookie = null; else cookie = pair;
    }

    let data = null;
    const text = await res.text();
    if (text) { try { data = JSON.parse(text); } catch { data = text; } }
    return { status: res.status, body: data };
  }
  return {
    get:   (p)    => call('GET', p),
    post:  (p, b) => call('POST', p, b),
    put:   (p, b) => call('PUT', p, b),
    patch: (p, b) => call('PATCH', p, b),
    del:   (p)    => call('DELETE', p),
    // convenience: register and stay signed in
    async registerClub(email, clubName, password = 'parola-de-test-1') {
      const r = await call('POST', '/auth/register', { role: 'club', email, password, clubName });
      assert.equal(r.status, 201, `register ${email} failed: ${JSON.stringify(r.body)}`);
      return r.body.account;
    },
    async register(role, email, extra, password = 'parola-de-test-1') {
      const r = await call('POST', '/auth/register', { role, email, password, ...extra });
      assert.equal(r.status, 201, `register ${role} ${email} failed: ${JSON.stringify(r.body)}`);
      return r.body.account;
    },
  };
}

// Some assertions are about the RESPONSE rather than its body -- the
// cookie's flags, for instance -- and those need a request the jar has
// not already digested.
function baseUrl() { return base; }

// Some fixtures have no endpoint yet -- a membership is created by
// accepting a join request, and that flow is not built. Setting one up
// directly is honest about that: the test is about what /api/teams/mine
// ANSWERS, not about how the row got there.
function sql(text, params) { return pool.query(text, params); }

module.exports = { start, stop, reset, client, baseUrl, sql };
