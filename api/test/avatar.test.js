'use strict';
// =====================================================================
// PUT /api/me/avatar
// =====================================================================
// The picture used to be localStorage['rocodefest_avatar_' + name]:
// per-browser, keyed on a display name, invisible to everyone else. It
// is a column on all four subtype tables now.
//
// Two rules govern it and both are CHECK constraints, not JavaScript:
//
//   ck_<tbl>_avatar_size   length <= 200000
//   ck_<tbl>_avatar_shape  ^data:image/(png|jpeg|gif|webp);base64,
//
// So what these tests are really asking is whether the API carries a
// database refusal back as something a page can act on -- a 400 with the
// right message -- rather than the 500 an untranslated SQLSTATE gives.
// That is the same failure mode 22003 produced on categoryId 999999.
const { test, before, after, beforeEach } = require('node:test');
const assert = require('node:assert/strict');
const h = require('./helper');

// A one-pixel PNG, so the shape check passes on something that really is
// an image rather than a string shaped like one.
const PNG =
  'data:image/png;base64,' +
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==';

before(async () => { await h.start(); });
after(async () => { await h.stop(); });
beforeEach(async () => { await h.reset(); });

// ---------------------------------------------------------------------
// The positive control
// ---------------------------------------------------------------------
// Every rejection below is only worth something if this one works: the
// paired-negative rule the SQL suites use applies just as much here. A
// suite where nothing can be saved would refuse everything and look
// perfect.
test('un avatar valid se salveaza si vine inapoi din /auth/me', async () => {
  const c = h.client();
  await c.registerClub('avatar@test.ro', 'Clubul cu Poza');

  const before = await c.get('/auth/me');
  assert.equal(before.body.account.avatar, null,
    'un cont nou nu are avatar');

  const put = await c.put('/api/me/avatar', { avatar: PNG });
  assert.equal(put.status, 200, JSON.stringify(put.body));

  const after = await c.get('/auth/me');
  assert.equal(after.body.account.avatar, PNG,
    'imaginea trebuie sa ajunga in profil, nu doar sa fie acceptata');
});

test('avatarul se sterge cu null', async () => {
  const c = h.client();
  await c.registerClub('sterge@test.ro', 'Clubul Fara Poza');
  await c.put('/api/me/avatar', { avatar: PNG });

  const del = await c.put('/api/me/avatar', { avatar: null });
  assert.equal(del.status, 200);

  const me = await c.get('/auth/me');
  assert.equal(me.body.account.avatar, null);
});

// ---------------------------------------------------------------------
// Each of the four roles
// ---------------------------------------------------------------------
// The endpoint picks its table from the session's role. A map with a
// wrong entry would still pass for clubs alone, which is why this runs
// the same assertion on all four rather than on the one that was
// written first.
const ROLES = [
  ['club',    { clubName: 'Club Avatar' }],
  ['member',  { fullName: 'Membru Avatar' }],
  ['judge',   { fullName: 'Arbitru Avatar' }],
  ['partner', { contactName: 'Contact Avatar', partnerType: 'sponsor' }],
];

for (const [role, extra] of ROLES) {
  test(`avatarul functioneaza pentru rolul ${role}`, async () => {
    const c = h.client();
    await c.register(role, `av-${role}@test.ro`, extra);

    const put = await c.put('/api/me/avatar', { avatar: PNG });
    assert.equal(put.status, 200, `${role}: ${JSON.stringify(put.body)}`);

    const me = await c.get('/auth/me');
    assert.equal(me.body.account.avatar, PNG, `${role} nu si-a primit avatarul inapoi`);
  });
}

// ---------------------------------------------------------------------
// The refusals -- and the status each one arrives with
// ---------------------------------------------------------------------
test('un fisier care nu e imagine este refuzat cu 400, nu cu 500', async () => {
  const c = h.client();
  await c.registerClub('forma@test.ro', 'Clubul Formei');

  const r = await c.put('/api/me/avatar', { avatar: 'salut, sunt un text' });
  assert.equal(r.status, 400,
    'ck_avatar_shape trebuie tradus in 400; un 500 inseamna SQLSTATE netradus');
  assert.match(r.body.error, /imagine/i,
    'mesajul trebuie sa spuna CE e gresit, nu doar ca a esuat');

  const me = await c.get('/auth/me');
  assert.equal(me.body.account.avatar, null, 'refuzul nu are voie sa lase nimic salvat');
});

test('un data URI de alt tip (svg) este refuzat', async () => {
  const c = h.client();
  await c.registerClub('svg@test.ro', 'Clubul SVG');

  // Shaped exactly like the accepted ones apart from the media type --
  // this is what tells us the check reads the list and does not merely
  // look for the words "data:image".
  const r = await c.put('/api/me/avatar', { avatar: 'data:image/svg+xml;base64,PHN2Zy8+' });
  assert.equal(r.status, 400, 'svg poate contine script, deci nu e in lista');
});

test('o imagine prea mare este refuzata cu un mesaj despre dimensiune', async () => {
  const c = h.client();
  await c.registerClub('marime@test.ro', 'Clubul Mare');

  const huge = 'data:image/png;base64,' + 'A'.repeat(200001);
  const r = await c.put('/api/me/avatar', { avatar: huge });
  assert.equal(r.status, 400, JSON.stringify(r.body));
  assert.match(r.body.error, /mare|KB/i,
    'trebuie sa fie mesajul de dimensiune, nu cel de forma -- ' +
    'altfel cineva cu o poza buna dar mare afla ca "nu e o imagine"');
});

test('un tip gresit (numar) este refuzat inainte sa ajunga la baza', async () => {
  const c = h.client();
  await c.registerClub('tip@test.ro', 'Clubul Tipului');

  const r = await c.put('/api/me/avatar', { avatar: 42 });
  assert.equal(r.status, 400);
});

// ---------------------------------------------------------------------
// Who is allowed to do this
// ---------------------------------------------------------------------
test('nesemnat nu poate scrie un avatar', async () => {
  const c = h.client();
  const r = await c.put('/api/me/avatar', { avatar: PNG });
  assert.equal(r.status, 401,
    'fara asta, oricine ar putea scrie in profilul oricui');
});

test('un cont nu poate scrie peste avatarul altuia', async () => {
  // There is no id in the URL to tamper with -- the row is chosen by
  // account_id from the session. This test exists to make that a
  // property that is checked rather than one that is believed: an
  // endpoint that later took an id in the body would fail here.
  const a = h.client();
  const b = h.client();
  await a.registerClub('a@test.ro', 'Clubul A');
  await b.registerClub('b@test.ro', 'Clubul B');

  await b.put('/api/me/avatar', { avatar: PNG });

  const meA = await a.get('/auth/me');
  assert.equal(meA.body.account.avatar, null,
    'clubul A nu are avatar; daca are, ruta a scris in randul gresit');
});
