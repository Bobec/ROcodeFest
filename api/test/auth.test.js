'use strict';
// =====================================================================
// Authentication
// =====================================================================
// The pages had none of this: signing in matched an email against a list
// in localStorage, so any registered address let you in. Everything here
// exists because that had to change, and every assertion below is one
// step away from silently reverting to it.
const { test, before, after, beforeEach } = require('node:test');
const assert = require('node:assert/strict');
const { start, stop, reset, client, baseUrl } = require('./helper');

before(start);
after(stop);
beforeEach(reset);

test('registration creates an account and signs it in', async () => {
  const c = client();
  const r = await c.post('/auth/register', {
    role: 'club', email: 'club@test.ro', password: 'parola-de-test-1',
    clubName: 'Clubul Unu', city: 'Cluj',
  });
  assert.equal(r.status, 201);
  assert.equal(r.body.account.role, 'club');

  // the session arrives with the response, so the next call is already
  // authenticated -- registering and then being asked to sign in would
  // be a worse experience for no gain
  const me = await c.get('/auth/me');
  assert.equal(me.body.account.email, 'club@test.ro');
  assert.equal(me.body.account.clubName, 'Clubul Unu');
});

test('the founding number comes from the database, not the browser', async () => {
  // The page used to compute this as "how many clubs I can see, plus
  // one", which two people registering at once would have made the same.
  const a = client(), b = client();
  await a.registerClub('unu@test.ro', 'Clubul Unu');
  await b.registerClub('doi@test.ro', 'Clubul Doi');

  const n1 = (await a.get('/auth/me')).body.account.foundingNumber;
  const n2 = (await b.get('/auth/me')).body.account.foundingNumber;
  assert.ok(n1 && n2, 'both clubs have a founding number');
  assert.notEqual(n1, n2, `founding numbers must differ, got ${n1} and ${n2}`);
});

test('a short password is refused, and creates nothing', async () => {
  const c = client();
  const r = await c.post('/auth/register', {
    role: 'club', email: 'scurt@test.ro', password: 'scurta', clubName: 'Clubul Scurt',
  });
  assert.equal(r.status, 400);

  // the control that makes the refusal mean something: the same
  // registration with an acceptable password goes through, so the 400
  // was about the password and not about the request being malformed
  const ok = await c.post('/auth/register', {
    role: 'club', email: 'scurt@test.ro', password: 'parola-de-test-1', clubName: 'Clubul Scurt',
  });
  assert.equal(ok.status, 201);
});

test('a duplicate email is refused with 409, and says which field', async () => {
  const a = client(), b = client();
  await a.registerClub('acelasi@test.ro', 'Primul Club');

  const r = await b.post('/auth/register', {
    role: 'club', email: 'acelasi@test.ro', password: 'parola-de-test-1', clubName: 'Alt Club',
  });
  assert.equal(r.status, 409, 'a collision is a conflict, not a 500');
  assert.match(r.body.error, /email/i, 'the message names the field to change');
});

test('a duplicate club name is refused, and names the OTHER field', async () => {
  const a = client(), b = client();
  await a.registerClub('primul@test.ro', 'Nume Duplicat');

  const r = await b.post('/auth/register', {
    role: 'club', email: 'al-doilea@test.ro', password: 'parola-de-test-1', clubName: 'Nume Duplicat',
  });
  assert.equal(r.status, 409);
  assert.match(r.body.error, /club/i,
    'a duplicate name and a duplicate email must not give the same message');
});

test('registration is atomic: a refused club leaves no orphan account', async () => {
  // enforce_subtype_role refuses a clubs row whose account has the wrong
  // role, and R8 now refuses to change that role afterwards -- so an
  // account committed without its club row could not even be repaired.
  const a = client(), b = client();
  await a.registerClub('atomic@test.ro', 'Club Atomic');

  const r = await b.post('/auth/register', {
    role: 'club', email: 'nou@test.ro', password: 'parola-de-test-1', clubName: 'Club Atomic',
  });
  assert.equal(r.status, 409);

  // the account from the failed half must not exist: signing in with it
  // is the way a user would discover that it did
  const login = await b.post('/auth/login', { email: 'nou@test.ro', password: 'parola-de-test-1' });
  assert.equal(login.status, 401, 'the rolled-back account cannot be signed in to');
});

test('signing in requires the real password', async () => {
  const c = client();
  await c.registerClub('login@test.ro', 'Club Login', 'parola-corecta-1');
  await c.post('/auth/logout');

  const bad = await c.post('/auth/login', { email: 'login@test.ro', password: 'parola-gresita' });
  assert.equal(bad.status, 401);

  const good = await c.post('/auth/login', { email: 'login@test.ro', password: 'parola-corecta-1' });
  assert.equal(good.status, 200, 'the control: the right password still works');
  assert.equal(good.body.account.role, 'club');
});

test('a wrong password and an unknown address are indistinguishable', async () => {
  // Otherwise the sign-in form becomes a way to find out which addresses
  // are registered: try one, read the difference in the answer.
  const c = client();
  await c.registerClub('exista@test.ro', 'Club Exista');
  await c.post('/auth/logout');

  const wrongPassword = await c.post('/auth/login', { email: 'exista@test.ro', password: 'gresita-total' });
  const noSuchAccount = await c.post('/auth/login', { email: 'nu-exista@test.ro', password: 'gresita-total' });

  assert.equal(wrongPassword.status, noSuchAccount.status, 'same status');
  assert.deepEqual(wrongPassword.body, noSuchAccount.body, 'same body, byte for byte');
});

test('one logout ends the session, whatever it was', async () => {
  // The pages keep four session keys and each sign-out page clears one,
  // which is finding S4. There is one session here, and one call ends it.
  const c = client();
  await c.registerClub('iesire@test.ro', 'Club Iesire');
  assert.ok((await c.get('/auth/me')).body.account, 'signed in to begin with');

  const out = await c.post('/auth/logout');
  assert.equal(out.status, 204);

  assert.equal((await c.get('/auth/me')).body.account, null, '/auth/me reports nobody');
  assert.equal((await c.get('/api/clubs/me')).status, 401, 'and protected routes refuse');
});

test('the session cookie is httpOnly', async () => {
  // A token kept in localStorage is readable by any script on the page,
  // and all 29 pages run inline script. httpOnly is the one property
  // page code cannot work around, so it is asserted on the real response
  // rather than assumed from the configuration.
  const res = await fetch(`${baseUrl()}/auth/register`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
      role: 'club', email: 'cookie@test.ro', password: 'parola-de-test-1', clubName: 'Club Cookie',
    }),
  });
  assert.equal(res.status, 201);

  const cookies = res.headers.getSetCookie();
  assert.ok(cookies.length > 0, 'a session cookie was actually set');
  const session = cookies.find((c) => c.startsWith('rocodefest.sid='));
  assert.ok(session, 'the session cookie is the one named in the config');
  assert.match(session, /HttpOnly/i, 'page scripts must not be able to read it');
  assert.match(session, /SameSite=Lax/i, 'and it must not ride along on cross-site requests');
});
