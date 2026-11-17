'use strict';
// =====================================================================
// The contact form
// =====================================================================
// The one write a stranger can reach: no account, no session. What it
// must do is keep a real message, refuse an empty or malformed one with
// a 400 (not a 500), keep nothing from a bot, and stop one address from
// filling the inbox. Reading is for organisers only.
const { test, before, after, beforeEach } = require('node:test');
const assert = require('node:assert/strict');
const h = require('./helper');
const auth = require('../auth');

before(async () => { await h.start(); });
after(async () => { await h.stop(); });
beforeEach(async () => {
  await h.reset();
  // contact_messages references no account, so the reset's truncate of
  // accounts does not reach it
  await h.sql('TRUNCATE oltp.contact_messages');
});

async function organizer() {
  const c = h.client();
  await h.sql(
    `WITH a AS (
       INSERT INTO oltp.accounts (email, password_hash, role)
       VALUES ('org@test.ro', $1, 'organizer') RETURNING account_id
     )
     INSERT INTO oltp.organizers (account_id, full_name)
     SELECT account_id, 'Organizatorul' FROM a`,
    [await auth.hash('parola-de-test-1')]
  );
  const login = await c.post('/auth/login', { email: 'org@test.ro', password: 'parola-de-test-1' });
  assert.equal(login.status, 200, JSON.stringify(login.body));
  return c;
}

const valid = { name: 'Ana Pop', email: 'ana@example.ro', message: 'Când se deschid înscrierile?' };

test('un mesaj trimis fara cont este pastrat', async () => {
  const anon = h.client();
  const r = await anon.post('/api/contact', valid);
  assert.equal(r.status, 201, JSON.stringify(r.body));

  const rows = (await h.sql('SELECT sender_name, sender_email, body, handled_at FROM oltp.contact_messages')).rows;
  assert.equal(rows.length, 1);
  assert.equal(rows[0].sender_name, 'Ana Pop');
  assert.equal(rows[0].sender_email, 'ana@example.ro');
  assert.equal(rows[0].body, 'Când se deschid înscrierile?');
  assert.equal(rows[0].handled_at, null);
});

test('campurile lipsa sau goale sunt un 400, nu un 500', async () => {
  const anon = h.client();
  for (const body of [
    { ...valid, name: '   ' },
    { ...valid, email: '' },
    { ...valid, message: '\n\n' },
    { ...valid, name: 42 },
    {},
  ]) {
    const r = await anon.post('/api/contact', body);
    assert.equal(r.status, 400, `${JSON.stringify(body)} -> ${r.status} ${JSON.stringify(r.body)}`);
  }
  assert.equal((await h.sql('SELECT count(*)::int AS n FROM oltp.contact_messages')).rows[0].n, 0);
});

test('o adresa fara forma de email si un mesaj prea lung sunt refuzate de baza, cu 400', async () => {
  const anon = h.client();
  const bad = await anon.post('/api/contact', { ...valid, email: 'asdf' });
  assert.equal(bad.status, 400, JSON.stringify(bad.body));
  assert.match(bad.body.error, /email/i);

  const long = await anon.post('/api/contact', { ...valid, message: 'x'.repeat(5001) });
  assert.equal(long.status, 400, JSON.stringify(long.body));

  const longName = await anon.post('/api/contact', { ...valid, name: 'n'.repeat(121) });
  assert.equal(longName.status, 400, JSON.stringify(longName.body));
});

test('un bot care completeaza campul ascuns primeste 201 si nu se pastreaza nimic', async () => {
  const anon = h.client();
  const r = await anon.post('/api/contact', { ...valid, website: 'http://spam.example' });
  assert.equal(r.status, 201);
  assert.equal((await h.sql('SELECT count(*)::int AS n FROM oltp.contact_messages')).rows[0].n, 0);
});

test('dupa 5 mesaje intr-o ora de la aceeasi adresa, al saselea este 429', async () => {
  const anon = h.client();
  for (let i = 0; i < 5; i++) {
    const r = await anon.post('/api/contact', { ...valid, message: `mesajul ${i}` });
    assert.equal(r.status, 201, JSON.stringify(r.body));
  }
  // the address is citext, so a different case is the same sender
  const sixth = await anon.post('/api/contact', { ...valid, email: 'ANA@example.ro' });
  assert.equal(sixth.status, 429, JSON.stringify(sixth.body));

  const other = await anon.post('/api/contact', { ...valid, email: 'altcineva@example.ro' });
  assert.equal(other.status, 201, 'limita este per adresa, nu globala');
});

test('doar un organizator citeste mesajele', async () => {
  await h.client().post('/api/contact', valid);

  const anon = h.client();
  assert.equal((await anon.get('/api/admin/contact-messages')).status, 401);

  const club = h.client();
  await club.registerClub('club@test.ro', 'Clubul de test');
  assert.equal((await club.get('/api/admin/contact-messages')).status, 403);

  const O = await organizer();
  const r = await O.get('/api/admin/contact-messages');
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.equal(r.body.messages.length, 1);
  assert.equal(r.body.messages[0].name, 'Ana Pop');
  assert.equal(r.body.messages[0].handledAt, null);
});

test('un mesaj marcat rezolvat trece la coada listei si poate fi redeschis', async () => {
  const anon = h.client();
  await anon.post('/api/contact', { ...valid, message: 'primul' });
  await anon.post('/api/contact', { ...valid, message: 'al doilea' });

  const O = await organizer();
  let list = (await O.get('/api/admin/contact-messages')).body.messages;
  assert.equal(list[0].body, 'al doilea', 'cel mai nou primul');
  const newest = list[0].id;

  const done = await O.patch(`/api/admin/contact-messages/${newest}`, { handled: true });
  assert.equal(done.status, 200, JSON.stringify(done.body));
  assert.ok(done.body.message.handledAt);

  list = (await O.get('/api/admin/contact-messages')).body.messages;
  assert.equal(list[0].body, 'primul', 'cele nerezolvate vin primele');
  assert.equal(list[1].id, newest);

  const reopened = await O.patch(`/api/admin/contact-messages/${newest}`, { handled: false });
  assert.equal(reopened.body.message.handledAt, null);

  assert.equal((await O.patch(`/api/admin/contact-messages/${newest}`, { handled: 'da' })).status, 400);
  assert.equal((await O.patch('/api/admin/contact-messages/999999', { handled: true })).status, 404);
});
