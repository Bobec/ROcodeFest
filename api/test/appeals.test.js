'use strict';
// =====================================================================
// Appeals
// =====================================================================
// rocodefest_appeals was an array in the filing club's own browser, so
// an appeal was addressed to nobody: no organiser could read it, and
// the club lost it on a different computer.
//
// The page also enforced "three rejected appeals and this team may file
// no more" by counting entries in that array. That is not a limit --
// clearing site data reset it, and it never applied to anyone else's
// browser. It is deliberately NOT reimplemented, and these tests say so
// rather than leaving its absence to be discovered.
const { test, before, after, beforeEach } = require('node:test');
const assert = require('node:assert/strict');
const h = require('./helper');

before(async () => { await h.start(); });
after(async () => { await h.stop(); });
beforeEach(async () => {
  await h.reset();
  await h.sql('TRUNCATE oltp.rules CASCADE');
});

async function club(email, name, code) {
  const c = h.client();
  await c.registerClub(email, name);
  const cats = (await c.get('/api/teams/categories')).body.categories;
  const t = await c.post('/api/teams', {
    teamName: 'Echipa ' + name, categoryId: cats[0].id, participationCode: code,
  });
  assert.equal(t.status, 201, JSON.stringify(t.body));
  return { c, team: t.body.team };
}

async function rule(code, title, retired = null) {
  // rule_sections.code is varchar(5) and unique, and sections survive
  // the truncate that clears rules, so this reuses one by code rather
  // than inserting a duplicate.
  const s = await h.sql(
    `INSERT INTO oltp.rule_sections (code, title, sort_order)
     VALUES ($1, $2, 1)
     ON CONFLICT (code) DO UPDATE SET title = EXCLUDED.title
     RETURNING section_id`,
    [code.substring(0, 5), 'Secțiunea ' + code]
  );
  const r = await h.sql(
    `INSERT INTO oltp.rules (section_id, code, title, body, retired_at)
     VALUES ($1, $2, $3, 'Textul regulii.', $4) RETURNING rule_id`,
    [s.rows[0].section_id, code, title, retired]
  );
  return String(r.rows[0].rule_id);
}

// ---------------------------------------------------------------------
// The positive control
// ---------------------------------------------------------------------
test('un club depune o contestatie si o vede inapoi', async () => {
  const A = await club('ap1@test.ro', 'Ap1', 'AP-1');

  const filed = await A.c.post('/api/appeals', {
    teamId: A.team.id,
    reason: 'Punctajul de la runda 2 nu corespunde cu ce s-a văzut în transmisiune.',
    timestamp: '1:23:45',
  });
  assert.equal(filed.status, 201, JSON.stringify(filed.body));
  assert.equal(filed.body.appeal.status, 'pending');

  const list = await A.c.get('/api/appeals');
  assert.equal(list.body.appeals.length, 1);
  assert.equal(list.body.appeals[0].teamName, A.team.teamName);
  assert.match(list.body.appeals[0].timestamp, /01:23:45/,
    'momentul din transmisiune este un INTERVAL, si se intoarce ca text');
});

test('o contestatie fara citare de regula este valida', async () => {
  // rule_id is nullable, and the regulations are not loaded yet -- a
  // club that cannot name a rule must still be able to appeal.
  const A = await club('ap2@test.ro', 'Ap2', 'AP-2');
  const r = await A.c.post('/api/appeals', {
    teamId: A.team.id, reason: 'Nu știm ce regulă, dar ceva nu e în regulă.',
  });
  assert.equal(r.status, 201, JSON.stringify(r.body));
});

// ---------------------------------------------------------------------
// Authorisation
// ---------------------------------------------------------------------
test('un club nu poate contesta pentru echipa altui club', async () => {
  const A = await club('apA@test.ro', 'ApA', 'AP-A');
  const B = await club('apB@test.ro', 'ApB', 'AP-B');

  const r = await B.c.post('/api/appeals', {
    teamId: A.team.id, reason: 'Contest pentru echipa altcuiva.',
  });
  assert.equal(r.status, 403);

  const none = await h.sql('SELECT count(*)::int AS n FROM oltp.appeals');
  assert.equal(none.rows[0].n, 0);
});

test('un club vede doar contestatiile lui', async () => {
  const A = await club('apC@test.ro', 'ApC', 'AP-C');
  const B = await club('apD@test.ro', 'ApD', 'AP-D');
  await A.c.post('/api/appeals', { teamId: A.team.id, reason: 'A mea.' });

  assert.equal((await A.c.get('/api/appeals')).body.appeals.length, 1);
  assert.deepEqual((await B.c.get('/api/appeals')).body.appeals, []);
});

test('un membru si un nesemnat nu pot contesta', async () => {
  const A = await club('apE@test.ro', 'ApE', 'AP-E');
  const m = h.client();
  await m.register('member', 'apmembru@test.ro', { fullName: 'Membru' });
  assert.equal((await m.post('/api/appeals', { teamId: A.team.id, reason: 'x' })).status, 403);

  const anon = h.client();
  assert.equal((await anon.post('/api/appeals', { teamId: A.team.id, reason: 'x' })).status, 401);
  assert.equal((await anon.get('/api/appeals')).status, 401);
});

// ---------------------------------------------------------------------
// Rule citations
// ---------------------------------------------------------------------
test('lista de reguli vine din tabel, nu din pagina', async () => {
  // The page had twelve codes written into it and the table had no rows
  // behind any of them, so citing one could never have produced an
  // appeal. An empty table is now an empty list rather than twelve
  // names that resolve to nothing.
  const c = h.client();
  assert.deepEqual((await c.get('/api/appeals/rules')).body.rules, []);

  await rule('G2', 'Team size and eligibility');
  const list = (await c.get('/api/appeals/rules')).body.rules;
  assert.equal(list.length, 1);
  assert.equal(list[0].code, 'G2');
  assert.equal(list[0].title, 'Team size and eligibility');
});

test('o regula citata apare pe contestatie, cu codul si titlul ei', async () => {
  const A = await club('apF@test.ro', 'ApF', 'AP-F');
  const ruleId = await rule('S2', 'Scoring rubric');

  const filed = await A.c.post('/api/appeals', {
    teamId: A.team.id, reason: 'Rubrica de punctaj nu a fost aplicată.', ruleId: ruleId,
  });
  assert.equal(filed.status, 201, JSON.stringify(filed.body));

  const got = (await A.c.get('/api/appeals')).body.appeals[0];
  assert.equal(got.ruleCode, 'S2');
  assert.equal(got.ruleTitle, 'Scoring rubric');
});

test('o regula retrasa nu este oferita, si nici nu poate fi citata', async () => {
  // Two places on purpose: the listing keeps it out of the dropdown,
  // and refuse_retired_rule_citation makes it impossible regardless of
  // what the dropdown offered. Only the second is a guarantee.
  const A = await club('apG@test.ro', 'ApG', 'AP-G');
  const retiredId = await rule('X9', 'Regulă scoasă', new Date('2025-01-01'));

  const offered = (await A.c.get('/api/appeals/rules')).body.rules;
  assert.deepEqual(offered, [], 'o regulă retrasă nu apare în listă');

  const r = await A.c.post('/api/appeals', {
    teamId: A.team.id, reason: 'Citez o regulă retrasă.', ruleId: retiredId,
  });
  assert.notEqual(r.status, 201, 'trigger-ul refuză citarea');
  assert.ok(r.status < 500, 'refuzul trebuie tradus, nu lăsat ca eroare internă');
});

test('o regula inexistenta este 400, nu 500', async () => {
  const A = await club('apH@test.ro', 'ApH', 'AP-H');
  const r = await A.c.post('/api/appeals', {
    teamId: A.team.id, reason: 'Citez ceva ce nu există.', ruleId: 999999999,
  });
  assert.equal(r.status, 400, JSON.stringify(r.body));
});

// ---------------------------------------------------------------------
// Input the database would refuse
// ---------------------------------------------------------------------
test('un moment scris gresit este 400 cu un mesaj despre format', async () => {
  const A = await club('apI@test.ro', 'ApI', 'AP-I');
  const r = await A.c.post('/api/appeals', {
    teamId: A.team.id, reason: 'Motiv.', timestamp: 'imediat dupa pauza',
  });
  assert.equal(r.status, 400, JSON.stringify(r.body));
  assert.match(r.body.error, /ore:minute:secunde/);
});

test('un moment gol este acceptat ca lipsa, nu ca eroare', async () => {
  const A = await club('apJ@test.ro', 'ApJ', 'AP-J');
  const r = await A.c.post('/api/appeals', {
    teamId: A.team.id, reason: 'Fără moment.', timestamp: '',
  });
  assert.equal(r.status, 201, JSON.stringify(r.body));
  assert.equal((await A.c.get('/api/appeals')).body.appeals[0].timestamp, null);
});

test('motivul este obligatoriu', async () => {
  const A = await club('apK@test.ro', 'ApK', 'AP-K');
  assert.equal((await A.c.post('/api/appeals', { teamId: A.team.id })).status, 400);
  assert.equal((await A.c.post('/api/appeals', { teamId: A.team.id, reason: '   ' })).status, 400);
  assert.equal((await A.c.post('/api/appeals', { reason: 'Fără echipă.' })).status, 400);
});

// ---------------------------------------------------------------------
// The three-rejected-appeals limit
// ---------------------------------------------------------------------
test('a patra cerere dupa trei respinse este refuzata de BAZA, nu de pagina', async () => {
  // The page enforced this by counting entries in its own localStorage
  // array -- which reset with site data and applied to nobody else's
  // browser. It looked like a rule invented in the front end.
  //
  // It is not. enforce_appeal_limit has been in the schema all along
  // and says the same thing, for everyone, permanently. The page was
  // keeping a second copy of a real rule, which is exactly the drift
  // this migration exists to remove: the copy is gone, the original
  // does the work, and the API only has to carry the refusal back.
  const A = await club('apL@test.ro', 'ApL', 'AP-L');
  const underRule = await rule('A21', 'Appeals');
  // decided_by_account_id has TWO foreign keys: one to accounts and one
  // to judges (R7). Only a judge can close an appeal, so the fixture
  // registers one rather than reusing the club's own id.
  const judge = h.client();
  const j = await judge.register('judge', 'arbitruapel@test.ro', { fullName: 'Arbitru Apel' });

  // Three rejected appeals, filed and closed one at a time.
  for (let i = 0; i < 3; i++) {
    const r = await A.c.post('/api/appeals', { teamId: A.team.id, reason: 'Contestația ' + i });
    assert.equal(r.status, 201, `contestația ${i}: ${JSON.stringify(r.body)}`);
    // ck_appeals_closure_is_accountable (R7): a decided appeal must name
    // WHEN it was decided, by WHOM, and under WHICH rule. All three, or
    // it stays pending. The fixture supplies them rather than working
    // around the constraint -- that accountability is the point. And
    // decided_by has a second FK to judges, so only a judge can close
    // one.
    await h.sql(
      `UPDATE oltp.appeals
          SET status = 'rejected', decided_at = now(),
              decided_by_account_id = $1, decided_under_rule_id = $2
        WHERE status = 'pending'`,
      [j.id, underRule]
    );
  }

  const fourth = await A.c.post('/api/appeals', { teamId: A.team.id, reason: 'A patra.' });
  assert.notEqual(fourth.status, 201, 'enforce_appeal_limit refuză a patra');
  assert.ok(fourth.status < 500,
    'refuzul trebuie să ajungă ca ceva ce pagina poate arăta, nu ca eroare internă');
  assert.match(fourth.body.error, /limit of 3/,
    'mesajul trigger-ului este păstrat: numește echipa și limita');

  assert.equal((await A.c.get('/api/appeals')).body.appeals.length, 3,
    'a patra nu a fost scrisă');
});

test('limita se aplica pe echipa, nu pe club', async () => {
  // The control for the test above: without it, an implementation that
  // refused every fourth appeal from a CLUB would pass just as well,
  // and a club with two teams would lose appeals it was entitled to.
  const A = await club('apM@test.ro', 'ApM', 'AP-M');
  const underRule = await rule('A22', 'Appeals');
  const judge = h.client();
  const j = await judge.register('judge', 'arbitru2@test.ro', { fullName: 'Al Doilea' });

  const cats = (await A.c.get('/api/teams/categories')).body.categories;
  const second = await A.c.post('/api/teams', {
    teamName: 'A doua echipă', categoryId: cats[0].id, participationCode: 'AP-M2',
  });
  assert.equal(second.status, 201);

  for (let i = 0; i < 3; i++) {
    await A.c.post('/api/appeals', { teamId: A.team.id, reason: 'Prima echipă ' + i });
    await h.sql(
      `UPDATE oltp.appeals
          SET status = 'rejected', decided_at = now(),
              decided_by_account_id = $1, decided_under_rule_id = $2
        WHERE status = 'pending'`,
      [j.id, underRule]
    );
  }

  const other = await A.c.post('/api/appeals', {
    teamId: second.body.team.id, reason: 'A doua echipă are dreptul ei.',
  });
  assert.equal(other.status, 201, JSON.stringify(other.body));
});
