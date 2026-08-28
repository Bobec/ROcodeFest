'use strict';
// =====================================================================
// Submissions
// =====================================================================
// rocodefest_submissions was one array per browser, so a club could not
// see what its members had submitted, a member could not see the club's,
// and no judge could see anything -- which left the review,
// resubmission and scoring machinery in the schema unreachable from the
// site.
//
// The lifecycle rules are all triggers and constraints and are tested
// in the SQL suites. What is tested here is the half the database
// cannot express, which is finding T5: submitted_by_account_id is a
// bare FK, so the database checks that the account EXISTS and never
// that it has anything to do with the team.
const { test, before, after, beforeEach } = require('node:test');
const assert = require('node:assert/strict');
const h = require('./helper');

before(async () => { await h.start(); });
after(async () => { await h.stop(); });

// Seasons and challenges are organiser data with no endpoint -- there
// is no page that creates them. They are also not covered by the
// accounts cascade, so they are cleared explicitly here; without this
// the active-season unique index would refuse the second test's season
// and every failure after the first would be a fixture problem
// pretending to be a bug.
beforeEach(async () => {
  await h.reset();
  await h.sql('TRUNCATE oltp.seasons CASCADE');
});

async function season(deadline = null) {
  const s = await h.sql(
    `INSERT INTO oltp.seasons (name, start_date, is_active)
     VALUES ('Sezon de test', CURRENT_DATE, TRUE) RETURNING season_id`
  );
  // Two challenges, because a second submission for the SAME (team,
  // challenge) is a version 2 and enforce_resubmission_gate refuses it.
  // A test that wanted two independent submissions and used one
  // challenge would be testing the gate by accident.
  const c = await h.sql(
    `INSERT INTO oltp.challenges (season_id, category_id, name, stage, submission_deadline)
     VALUES ($1, NULL, 'Proba de test',  'city_challenge', $2),
            ($1, NULL, 'A doua proba',   'final',          $2)
     RETURNING challenge_id`,
    [s.rows[0].season_id, deadline]
  );
  return {
    seasonId: s.rows[0].season_id,
    challengeId:  String(c.rows[0].challenge_id),
    challengeId2: String(c.rows[1].challenge_id),
  };
}

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

async function memberOn(email, name, teamId) {
  const c = h.client();
  const acc = await c.register('member', email, { fullName: name });
  await h.sql('INSERT INTO oltp.memberships (team_id, member_id) VALUES ($1, $2)', [teamId, acc.id]);
  return { c, acc };
}

// ---------------------------------------------------------------------
// The positive control
// ---------------------------------------------------------------------
test('un club trimite o lucrare si o vede inapoi', async () => {
  const ch = await season();
  const A = await club('sub1@test.ro', 'Sub1', 'S-1');

  const posted = await A.c.post('/api/submissions', {
    teamId: A.team.id, challengeId: ch.challengeId,
    title: 'Robotul nostru', description: 'Merge.', linkUrl: 'https://exemplu.ro/robot',
  });
  assert.equal(posted.status, 201, JSON.stringify(posted.body));
  assert.equal(posted.body.submission.version, 1,
    'versiunea o pune trigger-ul, nu clientul');

  const list = await A.c.get('/api/submissions');
  assert.equal(list.body.submissions.length, 1);
  const s = list.body.submissions[0];
  assert.equal(s.title, 'Robotul nostru');
  assert.equal(s.teamName, A.team.teamName);
  assert.equal(s.challengeName, 'Proba de test');
  assert.equal(s.authorRole, 'club');
});

test('un club vede ce a trimis membrul lui, si membrul vede doar ce a trimis el', async () => {
  // The split the page described in its own wording and implemented by
  // filtering an array on an email address -- in a browser that only
  // ever held one person's array.
  const ch = await season();
  const A = await club('sub2@test.ro', 'Sub2', 'S-2');
  const M = await memberOn('membrusub@test.ro', 'Un Membru', A.team.id);

  // Different challenges: two submissions to the same one would be a
  // version 2, which the resubmission gate refuses.
  const fromClub   = await A.c.post('/api/submissions', { teamId: A.team.id, challengeId: ch.challengeId,  title: 'De la club' });
  const fromMember = await M.c.post('/api/submissions', { teamId: A.team.id, challengeId: ch.challengeId2, title: 'De la membru' });
  assert.equal(fromClub.status, 201, JSON.stringify(fromClub.body));
  assert.equal(fromMember.status, 201, JSON.stringify(fromMember.body));

  const clubSees = (await A.c.get('/api/submissions')).body.submissions;
  assert.equal(clubSees.length, 2, 'clubul vede tot ce vine de la echipele lui');

  const memberSees = (await M.c.get('/api/submissions')).body.submissions;
  assert.equal(memberSees.length, 1);
  assert.equal(memberSees[0].title, 'De la membru');
});

// ---------------------------------------------------------------------
// T5: the half the database leaves open
// ---------------------------------------------------------------------
test('un club nu poate trimite pentru echipa altui club', async () => {
  const ch = await season();
  const A = await club('t5a@test.ro', 'T5A', 'T5-1');
  const B = await club('t5b@test.ro', 'T5B', 'T5-2');

  const stolen = await B.c.post('/api/submissions', {
    teamId: A.team.id, challengeId: ch.challengeId, title: 'Nu e a mea',
  });
  assert.equal(stolen.status, 403,
    'baza verifica doar ca echipa EXISTA -- apartenenta este treaba API-ului');

  const none = await h.sql('SELECT count(*)::int AS n FROM oltp.submissions');
  assert.equal(none.rows[0].n, 0, 'refuzul nu are voie sa lase nimic scris');
});

test('un membru nu poate trimite pentru o echipa din care nu face parte', async () => {
  const ch = await season();
  const A = await club('t5c@test.ro', 'T5C', 'T5-3');
  const outsider = h.client();
  await outsider.register('member', 'strain@test.ro', { fullName: 'Strain' });

  const r = await outsider.post('/api/submissions', {
    teamId: A.team.id, challengeId: ch.challengeId, title: 'Ma bag si eu',
  });
  assert.equal(r.status, 403);
});

test('un membru care a plecat din echipa nu mai poate trimite pentru ea', async () => {
  // The membership is what grants this, and memberships end. An
  // accepted join request would not -- it stays accepted forever.
  const ch = await season();
  const A = await club('t5d@test.ro', 'T5D', 'T5-4');
  const M = await memberOn('plecatsub@test.ro', 'A Plecat', A.team.id);

  assert.equal((await M.c.post('/api/submissions', {
    teamId: A.team.id, challengeId: ch.challengeId, title: 'Cat inca sunt',
  })).status, 201);

  await h.sql('UPDATE oltp.memberships SET left_at = now() WHERE member_id = $1', [M.acc.id]);

  const after = await M.c.post('/api/submissions', {
    teamId: A.team.id, challengeId: ch.challengeId, title: 'Dupa ce am plecat',
  });
  assert.equal(after.status, 403);
});

test('nesemnat nu poate trimite si nu vede nimic', async () => {
  const ch = await season();
  const A = await club('anon2@test.ro', 'Anon2', 'AN-2');
  const anon = h.client();
  assert.equal((await anon.get('/api/submissions')).status, 401);
  assert.equal((await anon.post('/api/submissions', {
    teamId: A.team.id, challengeId: ch.challengeId, title: 'X',
  })).status, 401);
});

// ---------------------------------------------------------------------
// The rules the schema already holds
// ---------------------------------------------------------------------
test('a doua lucrare fara o cerere de reluare este refuzata, si nu cu 500', async () => {
  // enforce_resubmission_gate: version 2 needs a review on version 1
  // that asked for a resubmission. Nothing here re-implements that --
  // what is asserted is that the refusal arrives as something a page
  // can show, rather than as an internal error.
  const ch = await season();
  const A = await club('gate@test.ro', 'Gate', 'G-1');

  assert.equal((await A.c.post('/api/submissions', {
    teamId: A.team.id, challengeId: ch.challengeId, title: 'Prima',
  })).status, 201);

  const second = await A.c.post('/api/submissions', {
    teamId: A.team.id, challengeId: ch.challengeId, title: 'A doua',
  });
  assert.notEqual(second.status, 201, 'poarta de reluare trebuie sa refuze');
  assert.ok(second.status < 500,
    'un 500 ar insemna ca P0001 nu este tradus si pagina nu are ce arata');
});

test('o versiune noua este permisa dupa ce o recenzie o cere', async () => {
  // The control for the test above. Without it, a suite where every
  // second submission fails would look identical to one where the gate
  // works, and an implementation that simply refused everything would
  // pass.
  const ch = await season();
  const A = await club('gate2@test.ro', 'Gate2', 'G-2');
  const judge = h.client();
  const j = await judge.register('judge', 'arbitrugate@test.ro', { fullName: 'Arbitru' });

  const first = await A.c.post('/api/submissions', {
    teamId: A.team.id, challengeId: ch.challengeId, title: 'Prima',
  });

  await h.sql(
    `INSERT INTO oltp.submission_reviews
       (submission_id, judge_id, requires_resubmission, feedback, reviewed_at)
     VALUES ($1, $2, TRUE, 'Mai lucrati la sasiu.', now())`,
    [first.body.submission.id, j.id]
  );

  const second = await A.c.post('/api/submissions', {
    teamId: A.team.id, challengeId: ch.challengeId, title: 'A doua',
  });
  assert.equal(second.status, 201, JSON.stringify(second.body));
  assert.equal(second.body.submission.version, 2);
});

test('o proba inexistenta este 400, nu 500', async () => {
  const A = await club('proba@test.ro', 'Proba', 'P-1');
  const r = await A.c.post('/api/submissions', {
    teamId: A.team.id, challengeId: 999999999, title: 'Fara proba',
  });
  assert.equal(r.status, 400, JSON.stringify(r.body));
});

test('titlul si proba sunt obligatorii', async () => {
  const ch = await season();
  const A = await club('oblig@test.ro', 'Oblig', 'O-1');
  assert.equal((await A.c.post('/api/submissions', { teamId: A.team.id, challengeId: ch.challengeId })).status, 400);
  assert.equal((await A.c.post('/api/submissions', { teamId: A.team.id, title: 'Fara proba' })).status, 400);
});

// ---------------------------------------------------------------------
// Which challenges a team may be shown
// ---------------------------------------------------------------------
test('probele sunt cele ale sezonului activ, si doar pentru echipele mele', async () => {
  const ch = await season();
  const A = await club('prob@test.ro', 'Prob', 'PR-1');
  const B = await club('prob2@test.ro', 'Prob2', 'PR-2');

  const mine = await A.c.get('/api/submissions/challenges?teamId=' + A.team.id);
  assert.equal(mine.status, 200);
  assert.equal(mine.body.challenges.length, 2);
  assert.ok(mine.body.challenges.some(function(c){ return c.id === ch.challengeId; }));

  const theirs = await B.c.get('/api/submissions/challenges?teamId=' + A.team.id);
  assert.deepEqual(theirs.body.challenges, [],
    'clubul B nu are voie sa se uite la ce probe poate da echipa clubului A');
});

test('o proba dintr-un sezon inactiv nu este oferita', async () => {
  // Not "every challenge that exists" -- past seasons keep their
  // challenges, and offering them would let a team submit to last
  // year's contest.
  const ch = await season();
  const A = await club('inactivS@test.ro', 'InactivS', 'IS-1');
  assert.equal((await A.c.get('/api/submissions/challenges?teamId=' + A.team.id)).body.challenges.length, 2);

  await h.sql('UPDATE oltp.seasons SET is_active = FALSE');
  assert.deepEqual((await A.c.get('/api/submissions/challenges?teamId=' + A.team.id)).body.challenges, []);
});

test('o proba cu termenul depasit este oferita, dar marcata inchisa', async () => {
  // Hiding it would leave a team unable to see what it missed. The flag
  // is the honest form: shown, and shown as closed.
  await season(new Date(Date.now() - 86400000));
  const A = await club('termen@test.ro', 'Termen', 'TR-1');
  const list = (await A.c.get('/api/submissions/challenges?teamId=' + A.team.id)).body.challenges;
  assert.equal(list.length, 2);
  assert.ok(list.every(function(c){ return c.closed === true; }));
});

// ---------------------------------------------------------------------
// Editing and removing
// ---------------------------------------------------------------------
test('autorul isi poate edita lucrarea, si clubul pe a echipelor lui', async () => {
  const ch = await season();
  const A = await club('edit@test.ro', 'Edit', 'E-1');
  const M = await memberOn('editm@test.ro', 'Editor', A.team.id);

  const s = await M.c.post('/api/submissions', {
    teamId: A.team.id, challengeId: ch.challengeId, title: 'Titlu vechi',
  });
  const id = s.body.submission.id;

  const byAuthor = await M.c.patch('/api/submissions/' + id, { title: 'Titlu nou' });
  assert.equal(byAuthor.status, 200);
  assert.equal(byAuthor.body.submission.title, 'Titlu nou');

  const byClub = await A.c.patch('/api/submissions/' + id, { description: 'Nota clubului' });
  assert.equal(byClub.status, 200, 'clubul raspunde pentru echipele lui');
});

test('altcineva nu poate edita, si nu afla nici ca exista', async () => {
  const ch = await season();
  const A = await club('edit2@test.ro', 'Edit2', 'E-2');
  const B = await club('edit3@test.ro', 'Edit3', 'E-3');

  const s = await A.c.post('/api/submissions', {
    teamId: A.team.id, challengeId: ch.challengeId, title: 'A mea',
  });

  const r = await B.c.patch('/api/submissions/' + s.body.submission.id, { title: 'Acum e a mea' });
  assert.equal(r.status, 404);

  const still = await h.sql('SELECT title FROM oltp.submissions WHERE submission_id = $1', [s.body.submission.id]);
  assert.equal(still.rows[0].title, 'A mea');
});

test('doar ultima versiune dintr-un lant poate fi stearsa', async () => {
  // Deleting an earlier one would leave a version 3 whose version 2 is
  // gone, and enforce_resubmission_gate reads the predecessor to decide
  // whether the next version was allowed.
  const ch = await season();
  const A = await club('sterg@test.ro', 'Sterg', 'ST-1');
  const judge = h.client();
  const j = await judge.register('judge', 'arbitrusterg@test.ro', { fullName: 'Arbitru' });

  const v1 = await A.c.post('/api/submissions', { teamId: A.team.id, challengeId: ch.challengeId, title: 'V1' });
  await h.sql(
    `INSERT INTO oltp.submission_reviews (submission_id, judge_id, requires_resubmission, feedback, reviewed_at)
     VALUES ($1, $2, TRUE, 'Inca o tura.', now())`,
    [v1.body.submission.id, j.id]
  );
  const v2 = await A.c.post('/api/submissions', { teamId: A.team.id, challengeId: ch.challengeId, title: 'V2' });
  assert.equal(v2.body.submission.version, 2);

  const older = await A.c.del('/api/submissions/' + v1.body.submission.id);
  assert.equal(older.status, 404, 'v1 nu este ultima din lant');

  const newest = await A.c.del('/api/submissions/' + v2.body.submission.id);
  assert.equal(newest.status, 200, JSON.stringify(newest.body));

  const left = await h.sql('SELECT count(*)::int AS n FROM oltp.submissions');
  assert.equal(left.rows[0].n, 1, 'a plecat exact una');
});

test('altcineva nu poate sterge o lucrare', async () => {
  const ch = await season();
  const A = await club('sterg2@test.ro', 'Sterg2', 'ST-2');
  const B = await club('sterg3@test.ro', 'Sterg3', 'ST-3');

  const s = await A.c.post('/api/submissions', {
    teamId: A.team.id, challengeId: ch.challengeId, title: 'Nu o stergi',
  });

  assert.equal((await B.c.del('/api/submissions/' + s.body.submission.id)).status, 404);
  const still = await h.sql('SELECT count(*)::int AS n FROM oltp.submissions');
  assert.equal(still.rows[0].n, 1);
});
