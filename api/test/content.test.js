'use strict';
// =====================================================================
// News and the run of show
// =====================================================================
// news.html was an empty state with nothing behind it. events.html and
// contest-day.html each showed a hardcoded agenda -- two hand-maintained
// copies of one timetable, which is a pair that eventually disagrees.
//
// Both now come from the database, and the schedule merges two streams:
// matches carry their own scheduled_at and are NOT copied into
// schedule_items, because two copies of a time are two times that
// disagree the moment one of them moves.
const { test, before, after, beforeEach } = require('node:test');
const assert = require('node:assert/strict');
const h = require('./helper');
const auth = require('../auth');

before(async () => { await h.start(); });
after(async () => { await h.stop(); });
beforeEach(async () => {
  await h.reset();
  await h.sql('TRUNCATE oltp.seasons CASCADE');
  await h.sql('TRUNCATE oltp.news_posts CASCADE');
});

async function organizer(email = 'org@test.ro', name = 'Organizatorul') {
  const c = h.client();
  const r = await h.sql(
    `WITH a AS (
       INSERT INTO oltp.accounts (email, password_hash, role)
       VALUES ($1, $2, 'organizer') RETURNING account_id
     )
     INSERT INTO oltp.organizers (account_id, full_name)
     SELECT account_id, $3 FROM a RETURNING account_id`,
    [email, await auth.hash('parola-de-test-1'), name]
  );
  const login = await c.post('/auth/login', { email, password: 'parola-de-test-1' });
  assert.equal(login.status, 200, JSON.stringify(login.body));
  return { c, id: String(r.rows[0].account_id) };
}

async function season(active = true) {
  const s = await h.sql(
    `INSERT INTO oltp.seasons (name, start_date, is_active)
     VALUES ('Sezon continut', CURRENT_DATE, $1) RETURNING season_id`, [active]);
  return String(s.rows[0].season_id);
}

// ---------------------------------------------------------------------
// News
// ---------------------------------------------------------------------
test('un articol publicat este vizibil oricui', async () => {
  const O = await organizer();
  const r = await O.c.post('/api/news', {
    title: 'S-au deschis înscrierile', summary: 'Cluburile se pot înregistra.',
    body: 'Textul complet.', publish: true,
  });
  assert.equal(r.status, 201, JSON.stringify(r.body));

  const anon = h.client();
  const list = await anon.get('/api/news');
  assert.equal(list.status, 200);
  assert.equal(list.body.news.length, 1);
  assert.equal(list.body.news[0].title, 'S-au deschis înscrierile');
  assert.equal(list.body.news[0].authorName, 'Organizatorul');
});

test('o ciorna nu este vizibila public, dar autorul o vede', async () => {
  // published_at is nullable, so a draft is a row without a date rather
  // than a status column that would need its own rules about which
  // transitions are legal.
  const O = await organizer();
  await O.c.post('/api/news', { title: 'Nepublicat', body: 'Încă lucrez la el.', publish: false });

  const anon = h.client();
  assert.deepEqual((await anon.get('/api/news')).body.news, []);

  const mine = await O.c.get('/api/news');
  assert.equal(mine.body.news.length, 1, 'altfel nu ai cum sa-ti vezi ciorna dupa ce ai scris-o');
  assert.equal(mine.body.news[0].publishedAt, null);
});

test('o ciorna raspunde 404 celorlalti, nu 403', async () => {
  // That a draft EXISTS is itself not public. A 403 would confirm it.
  const O = await organizer();
  const d = await O.c.post('/api/news', { title: 'Secret', body: 'x', publish: false });

  const anon = h.client();
  assert.equal((await anon.get('/api/news/' + d.body.article.id)).status, 404);
  assert.equal((await O.c.get('/api/news/' + d.body.article.id)).status, 200);
});

test('publicarea si retragerea sunt reversibile', async () => {
  const O = await organizer();
  const a = await O.c.post('/api/news', { title: 'Basculant', body: 'x', publish: true });
  const anon = h.client();
  assert.equal((await anon.get('/api/news')).body.news.length, 1);

  await O.c.patch('/api/news/' + a.body.article.id, { publish: false });
  assert.equal((await anon.get('/api/news')).body.news.length, 0);

  await O.c.patch('/api/news/' + a.body.article.id, { publish: true });
  assert.equal((await anon.get('/api/news')).body.news.length, 1);
});

test('republicarea nu muta articolul inapoi in varf', async () => {
  // published_at is stamped only when it is not already set. Otherwise
  // fixing a typo in an old article would push it to the top of the
  // news page as though it were new.
  const O = await organizer();
  const a = await O.c.post('/api/news', { title: 'Vechi', body: 'x', publish: true });
  const first = (await O.c.get('/api/news')).body.news[0].publishedAt;

  await O.c.patch('/api/news/' + a.body.article.id, { title: 'Vechi (corectat)', publish: true });
  const after = (await O.c.get('/api/news')).body.news[0];
  assert.equal(after.title, 'Vechi (corectat)');
  assert.equal(after.publishedAt, first, 'data publicarii ramane cea initiala');
});

test('doar organizatorii scriu stiri', async () => {
  const club = h.client(); await club.registerClub('nclub@test.ro', 'Clubul');
  const anon = h.client();
  assert.equal((await club.post('/api/news', { title: 'x', body: 'y' })).status, 403);
  assert.equal((await anon.post('/api/news', { title: 'x', body: 'y' })).status, 401);
});

test('titlul si textul sunt obligatorii', async () => {
  const O = await organizer();
  assert.equal((await O.c.post('/api/news', { body: 'fara titlu' })).status, 400);
  assert.equal((await O.c.post('/api/news', { title: 'fara text' })).status, 400);
  assert.equal((await O.c.post('/api/news', { title: '   ', body: 'y' })).status, 400);
});

// ---------------------------------------------------------------------
// The schedule
// ---------------------------------------------------------------------
test('programul este public si tine de sezonul activ', async () => {
  const O = await organizer();
  const s = await season(true);
  const r = await O.c.post('/api/schedule', {
    seasonId: s, kind: 'break', title: 'Pauza de masă',
    startsAt: '2026-11-14T12:00:00Z', endsAt: '2026-11-14T13:00:00Z', location: 'Foaier',
  });
  assert.equal(r.status, 201, JSON.stringify(r.body));

  const anon = h.client();
  const sched = await anon.get('/api/schedule');
  assert.equal(sched.status, 200);
  assert.equal(sched.body.season.name, 'Sezon continut');
  assert.equal(sched.body.items.length, 1);
  assert.equal(sched.body.items[0].title, 'Pauza de masă');
});

test('meciurile apar in program fara sa fie copiate acolo', async () => {
  // This is the whole design. A match keeps its own scheduled_at, and
  // the schedule merges the two streams by time -- so moving a match
  // moves it in the timetable, with nothing to keep in sync.
  const O = await organizer();
  const s = await season(true);
  const ch = await h.sql(
    `INSERT INTO oltp.challenges (season_id, name, stage)
     VALUES ($1, 'Proba', 'final') RETURNING challenge_id`, [s]);
  await h.sql(
    `INSERT INTO oltp.matches (challenge_id, round_name, scheduled_at, location)
     VALUES ($1, 'Semifinala A', '2026-11-14T10:00:00Z', 'Sala mare')`,
    [ch.rows[0].challenge_id]);

  await O.c.post('/api/schedule', {
    seasonId: s, kind: 'break', title: 'Pauză', startsAt: '2026-11-14T12:00:00Z',
  });

  const anon = h.client();
  const items = (await anon.get('/api/schedule')).body.items;
  assert.equal(items.length, 2, 'meciul si pauza, in acelasi program');
  assert.equal(items[0].title, 'Semifinala A', 'ordonate dupa ora');
  assert.equal(items[0].kind, 'match');
  assert.equal(items[0].id, null, 'meciul nu are rand propriu in schedule_items');
  assert.equal(items[1].title, 'Pauză');

  const rows = await h.sql('SELECT count(*)::int AS n FROM oltp.schedule_items');
  assert.equal(rows.rows[0].n, 1, 'o singura intrare scrisa: pauza');
});

test('un meci fara ora nu apare in program', async () => {
  // Otherwise the timetable would list an item with no time on it.
  const O = await organizer();
  const s = await season(true);
  const ch = await h.sql(
    `INSERT INTO oltp.challenges (season_id, name, stage)
     VALUES ($1, 'Proba', 'final') RETURNING challenge_id`, [s]);
  await h.sql(
    `INSERT INTO oltp.matches (challenge_id, round_name) VALUES ($1, 'Neprogramat')`,
    [ch.rows[0].challenge_id]);

  const anon = h.client();
  assert.deepEqual((await anon.get('/api/schedule')).body.items, []);
  assert.ok(O.c);
});

test('o intrare care nu e meci nu poate fi legata de un meci', async () => {
  const O = await organizer();
  const s = await season(true);
  const ch = await h.sql(
    `INSERT INTO oltp.challenges (season_id, name, stage)
     VALUES ($1, 'Proba', 'final') RETURNING challenge_id`, [s]);
  const m = await h.sql(
    `INSERT INTO oltp.matches (challenge_id) VALUES ($1) RETURNING match_id`,
    [ch.rows[0].challenge_id]);

  const r = await O.c.post('/api/schedule', {
    seasonId: s, kind: 'break', title: 'Pauză cu meci',
    startsAt: '2026-11-14T12:00:00Z', matchId: String(m.rows[0].match_id),
  });
  assert.equal(r.status, 400, JSON.stringify(r.body));
  assert.match(r.body.error, /match/i,
    'altfel pagina ar desena o pauza acolo unde e un meci');
});

test('un meci nu poate aparea de doua ori in program', async () => {
  const O = await organizer();
  const s = await season(true);
  const ch = await h.sql(
    `INSERT INTO oltp.challenges (season_id, name, stage)
     VALUES ($1, 'Proba', 'final') RETURNING challenge_id`, [s]);
  const m = await h.sql(
    `INSERT INTO oltp.matches (challenge_id) VALUES ($1) RETURNING match_id`,
    [ch.rows[0].challenge_id]);
  const mid = String(m.rows[0].match_id);

  const body = {
    seasonId: s, kind: 'match', title: 'Semifinala A',
    startsAt: '2026-11-14T10:00:00Z', matchId: mid,
  };
  assert.equal((await O.c.post('/api/schedule', body)).status, 201);

  const again = await O.c.post('/api/schedule', Object.assign({}, body, { title: 'Din nou' }));
  assert.equal(again.status, 409, JSON.stringify(again.body));
  assert.match(again.body.error, /deja/i);
});

test('o ora de sfarsit inaintea celei de inceput este 400', async () => {
  const O = await organizer();
  const s = await season(true);
  const r = await O.c.post('/api/schedule', {
    seasonId: s, kind: 'break', title: 'Invers',
    startsAt: '2026-11-14T13:00:00Z', endsAt: '2026-11-14T12:00:00Z',
  });
  assert.equal(r.status, 400, JSON.stringify(r.body));
});

test('un tip inventat este 400 cu lista tipurilor', async () => {
  const O = await organizer();
  const s = await season(true);
  const r = await O.c.post('/api/schedule', {
    seasonId: s, kind: 'petrecere', title: 'X', startsAt: '2026-11-14T12:00:00Z',
  });
  assert.equal(r.status, 400, JSON.stringify(r.body));
  assert.match(r.body.error, /opening|break|awards/);
});

test('doar organizatorii scriu in program', async () => {
  const s = await season(true);
  const club = h.client(); await club.registerClub('sclub@test.ro', 'Clubul');
  const r = await club.post('/api/schedule', {
    seasonId: s, kind: 'break', title: 'x', startsAt: '2026-11-14T12:00:00Z',
  });
  assert.equal(r.status, 403);
});

test('fara sezon activ, programul este gol si o spune', async () => {
  const O = await organizer();
  const s = await season(false);
  await h.sql(
    `INSERT INTO oltp.schedule_items (season_id, kind, title, starts_at)
     VALUES ($1, 'break', 'Pauză', '2026-11-14T12:00:00Z')`, [s]);

  const anon = h.client();
  const sched = await anon.get('/api/schedule');
  assert.equal(sched.body.season, null);
  assert.deepEqual(sched.body.items, []);

  // But the season can still be asked for by name.
  const asked = await anon.get('/api/schedule?seasonId=' + s);
  assert.equal(asked.body.items.length, 1);
  assert.ok(O.c);
});

test('jaloanele vin din termenele probelor, nu din text scris in pagina', async () => {
  // events.html stated these as four sentences. Every one of them is
  // already a date somewhere, so nothing here is invented.
  const O = await organizer();
  const s = await season(true);
  await h.sql(
    `INSERT INTO oltp.challenges (season_id, name, stage, submission_deadline)
     VALUES ($1, 'Etapa orașului', 'city_challenge', '2026-09-30T23:59:00Z'),
            ($1, 'Finala', 'final', '2026-11-01T23:59:00Z')`, [s]);

  const anon = h.client();
  const sched = await anon.get('/api/schedule');
  assert.equal(sched.body.milestones.length, 2);
  assert.equal(sched.body.milestones[0].name, 'Etapa orașului', 'ordonate dupa termen');
  assert.ok(sched.body.season.startDate, 'data de inceput a sezonului vine si ea');
  assert.ok(O.c);
});
