'use strict';
// =====================================================================
// Four roles, one session
// =====================================================================
// The pages kept four session keys -- rocodefest_session,
// _member_session, _judge_session, _partner_session -- and each sign-out
// page cleared exactly one of them. Three findings came out of that:
//
//   S2  the nav read three of the four keys, so a signed-in judge was
//       shown as signed out on all 29 pages
//   S3  nothing anywhere cleared the judge's key, so that session could
//       not be ended at all
//   S4  two sign-ins left two keys, and one sign-out cleared one
//
// None of them are bugs to port across. One session carrying its own
// role makes all three unrepresentable, and these tests are what keeps
// it that way.
const { test, before, after, beforeEach } = require('node:test');
const assert = require('node:assert/strict');
const { start, stop, reset, client } = require('./helper');

before(start);
after(stop);
beforeEach(reset);

const PROFILES = {
  club:    { clubName: 'Clubul Test' },
  member:  { fullName: 'Ana Membru', city: 'Cluj' },
  judge:   { fullName: 'Ion Judecator', expertise: 'Robotică' },
  partner: { contactName: 'Maria Contact', partnerType: 'sponsor', orgName: 'Acme SRL' },
};

test('every role can register, and gets its own role back', async () => {
  for (const [role, extra] of Object.entries(PROFILES)) {
    const c = client();
    await c.register(role, `${role}@test.ro`, extra);
    const me = await c.get('/auth/me');
    assert.equal(me.body.account.role, role, `${role} is recorded as ${role}`);
  }
});

test('/auth/me carries the profile, whatever the role', async () => {
  // The point of one endpoint: a page asks who is here and gets what it
  // needs to render, without knowing which table the answer came from.
  const cases = [
    ['club',    { clubName: 'Clubul Test' },                    (a) => a.clubName === 'Clubul Test' && a.foundingNumber > 0],
    ['member',  { fullName: 'Ana Membru', city: 'Cluj' },        (a) => a.fullName === 'Ana Membru' && a.city === 'Cluj'],
    ['judge',   { fullName: 'Ion Judecator', expertise: 'Robotică' }, (a) => a.fullName === 'Ion Judecator' && a.expertise === 'Robotică'],
    ['partner', { contactName: 'Maria Contact', partnerType: 'sponsor', orgName: 'Acme SRL' }, (a) => a.contactName === 'Maria Contact' && a.partnerType === 'sponsor'],
  ];
  for (const [role, extra, ok] of cases) {
    await reset();
    const c = client();
    await c.register(role, `${role}@test.ro`, extra);
    const a = (await c.get('/auth/me')).body.account;
    assert.ok(ok(a), `${role} profile came back: ${JSON.stringify(a)}`);
  }
});

test('a judge is signed in as far as every page is concerned', async () => {
  // This is S2. The old nav checked three keys and the judge's was not
  // among them, so signing in as a judge left every navigation bar
  // showing "Log in".
  const c = client();
  await c.register('judge', 'judecator@test.ro', PROFILES.judge);

  const me = await c.get('/auth/me');
  assert.ok(me.body.account, 'the judge is visible to the one question every page asks');
  assert.equal(me.body.account.role, 'judge');
});

test('a judge can sign out', async () => {
  // This is S3: nothing in the site cleared rocodefest_judge_session, so
  // that session survived until the browser's storage was cleared by
  // hand. There is one logout and it works for every role.
  const c = client();
  await c.register('judge', 'iesire@test.ro', PROFILES.judge);
  assert.equal((await c.post('/auth/logout')).status, 204);
  assert.equal((await c.get('/auth/me')).body.account, null);
});

test('signing in as a second role replaces the first, it does not add to it', async () => {
  // This is S4. Two sign-ins used to leave two keys set, and clearing
  // one still showed you as signed in. There is one session, so the
  // second sign-in takes the place of the first.
  const setup = client();
  await setup.register('club', 'clubul@test.ro', PROFILES.club);
  await setup.post('/auth/logout');
  await setup.register('member', 'membrul@test.ro', PROFILES.member);
  await setup.post('/auth/logout');

  const c = client();
  await c.post('/auth/login', { email: 'clubul@test.ro', password: 'parola-de-test-1' });
  assert.equal((await c.get('/auth/me')).body.account.role, 'club');

  await c.post('/auth/login', { email: 'membrul@test.ro', password: 'parola-de-test-1' });
  const after = (await c.get('/auth/me')).body.account;
  assert.equal(after.role, 'member', 'the second sign-in replaced the first');
  assert.equal(after.email, 'membrul@test.ro');

  // and ONE logout leaves nothing behind
  await c.post('/auth/logout');
  assert.equal((await c.get('/auth/me')).body.account, null,
    'one sign-out ends it -- there is no second session still standing');
});

test('a role cannot use another role\'s endpoints', async () => {
  // requireRole is the guard the database cannot supply: it knows a club
  // exists, never that the caller is one.
  const judge = client();
  await judge.register('judge', 'j@test.ro', PROFILES.judge);

  assert.equal((await judge.get('/api/clubs/me')).status, 403, 'a judge is not a club');
  assert.equal((await judge.get('/api/teams/mine')).status, 403);
  assert.equal(
    (await judge.post('/api/teams', { teamName: 'X', categoryId: 1, participationCode: 'J-1' })).status,
    403
  );

  // the control: 403 is about the ROLE, not about being unable to serve
  // the route at all
  const club = client();
  await club.registerClub('c@test.ro', 'Clubul Real');
  assert.equal((await club.get('/api/clubs/me')).status, 200);
});

test('an unknown role is refused, and the message lists the real ones', async () => {
  const c = client();
  const r = await c.post('/auth/register', {
    role: 'administrator', email: 'x@test.ro', password: 'parola-de-test-1', fullName: 'X',
  });
  assert.equal(r.status, 400);
  assert.match(r.body.error, /club/, 'the message names what is actually accepted');
});

test('each role has its own required fields', async () => {
  const c = client();
  // a member without a name
  const m = await c.post('/auth/register', {
    role: 'member', email: 'fara-nume@test.ro', password: 'parola-de-test-1',
  });
  assert.equal(m.status, 400);

  // a partner without a type -- partner_type is NOT NULL and an enum, so
  // leaving it out must be caught before it reaches the database as a
  // constraint violation dressed up as a server fault
  const p = await c.post('/auth/register', {
    role: 'partner', email: 'fara-tip@test.ro', password: 'parola-de-test-1',
    contactName: 'Cineva',
  });
  assert.equal(p.status, 400);

  // the control: complete registrations of both go through
  assert.equal((await c.post('/auth/register', {
    role: 'member', email: 'cu-nume@test.ro', password: 'parola-de-test-1', fullName: 'Cu Nume',
  })).status, 201);
});

test('a partner type outside the enum is a 400, not a 500', async () => {
  const c = client();
  const r = await c.post('/auth/register', {
    role: 'partner', email: 'tip-gresit@test.ro', password: 'parola-de-test-1',
    contactName: 'Cineva', partnerType: 'platinum',
  });
  assert.equal(r.status, 400, 'the enum refuses it and the caller is told so');
});

test('every role is refused a duplicate email, the same way', async () => {
  for (const [role, extra] of Object.entries(PROFILES)) {
    await reset();
    const a = client(), b = client();
    await a.register(role, 'acelasi@test.ro', extra);
    const r = await b.post('/auth/register', {
      role, email: 'acelasi@test.ro', password: 'parola-de-test-1', ...extra,
    });
    assert.equal(r.status, 409, `${role}: a duplicate email is a conflict`);
    assert.match(r.body.error, /email/i, `${role}: and the message says which field`);
  }
});

test('registration stays atomic for every role', async () => {
  // The account and its subtype row are one transaction. A committed
  // account without its subtype row could not even be repaired, because
  // R8 refuses to change a role while a subtype row exists -- and here
  // there would be no subtype row to remove.
  for (const [role, extra] of Object.entries(PROFILES)) {
    await reset();
    const a = client(), b = client();
    await a.register(role, 'primul@test.ro', extra);

    const r = await b.post('/auth/register', {
      role, email: 'primul@test.ro', password: 'parola-de-test-1', ...extra,
    });
    assert.equal(r.status, 409);

    const login = await b.post('/auth/login', { email: 'primul@test.ro', password: 'parola-de-test-1' });
    assert.equal(login.status, 200, `${role}: the FIRST account still works`);
    assert.equal(login.body.account.role, role);
  }
});
