'use strict';
// =====================================================================
// Forum
// =====================================================================
// rocodefest_forum was one array per browser, so the forum was a diary:
// every visitor saw only their own threads and a reply reached nobody.
//
// Two of the page's assumptions the schema does not allow, and both are
// asserted here so the change is recorded rather than rediscovered:
//
//   * guest posting -- forum_posts.author_account_id is NOT NULL
//   * authorship by display NAME -- which is why the page also looked
//     the avatar up under rocodefest_avatar_<name>, and why two
//     accounts sharing a name could edit each other's posts
const { test, before, after, beforeEach } = require('node:test');
const assert = require('node:assert/strict');
const h = require('./helper');

before(async () => { await h.start(); });
after(async () => { await h.stop(); });
beforeEach(async () => {
  await h.reset();
  // forum_posts cascade from accounts, but say so rather than assume.
  await h.sql('TRUNCATE oltp.forum_posts CASCADE');
});

const PNG =
  'data:image/png;base64,' +
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==';

async function club(email, name) {
  const c = h.client();
  await c.registerClub(email, name);
  return c;
}

// ---------------------------------------------------------------------
// Categories -- seeded reference data
// ---------------------------------------------------------------------
test('categoriile vin din tabel si sunt cele pe care le arata pagina', async () => {
  // forum_categories had no rows, and forum_posts.category_id is NOT
  // NULL, so no post the page composed could ever have become one.
  const anon = h.client();
  const r = await anon.get('/api/forum/categories');
  assert.equal(r.status, 200);
  const codes = r.body.categories.map(function (c) { return c.code; });
  for (const wanted of ['announcements', 'general', 'robotics', 'programming', 'design']) {
    assert.ok(codes.includes(wanted), `lipseste categoria ${wanted}`);
  }
});

// ---------------------------------------------------------------------
// The positive control
// ---------------------------------------------------------------------
test('un subiect postat de cineva este vazut de altcineva', async () => {
  // The whole point. In the old forum this was impossible: the post
  // went into the author's own browser.
  const A = await club('forumA@test.ro', 'Clubul A');
  const posted = await A.post('/api/forum/posts', {
    category: 'general', title: 'Ce roți folosiți?', body: 'Ne interesează tracțiunea.',
  });
  assert.equal(posted.status, 201, JSON.stringify(posted.body));

  const B = await club('forumB@test.ro', 'Clubul B');
  const seen = await B.get('/api/forum/posts?category=general');
  assert.equal(seen.body.posts.length, 1);
  assert.equal(seen.body.posts[0].title, 'Ce roți folosiți?');
  assert.equal(seen.body.posts[0].authorName, 'Clubul A');
  assert.equal(seen.body.posts[0].authorRole, 'club');
});

test('forumul este citibil si nesemnat', async () => {
  const A = await club('forumC@test.ro', 'Clubul C');
  await A.post('/api/forum/posts', { category: 'general', title: 'Public' });

  const anon = h.client();
  const r = await anon.get('/api/forum/posts?category=general');
  assert.equal(r.status, 200);
  assert.equal(r.body.posts.length, 1);
});

test('un raspuns ajunge la autorul subiectului', async () => {
  const A = await club('forumD@test.ro', 'Clubul D');
  const B = await club('forumE@test.ro', 'Clubul E');
  const p = await A.post('/api/forum/posts', { category: 'general', title: 'Întrebare' });

  const reply = await B.post('/api/forum/posts/' + p.body.post.id + '/comments', { body: 'Un răspuns.' });
  assert.equal(reply.status, 201, JSON.stringify(reply.body));

  const comments = await A.get('/api/forum/posts/' + p.body.post.id + '/comments');
  assert.equal(comments.body.comments.length, 1);
  assert.equal(comments.body.comments[0].authorName, 'Clubul E');

  const list = await A.get('/api/forum/posts?category=general');
  assert.equal(list.body.posts[0].commentCount, 1);
});

test('avatarul autorului vine cu postarea', async () => {
  // It used to be read from rocodefest_avatar_<author name> in the
  // READER's own browser, so a club only ever saw its own picture and
  // nobody else's -- the one case where the key could not possibly work.
  const A = await club('forumF@test.ro', 'Clubul cu Poză');
  await A.put('/api/me/avatar', { avatar: PNG });
  await A.post('/api/forum/posts', { category: 'general', title: 'Cu poză' });

  const B = await club('forumG@test.ro', 'Alt Club');
  const seen = await B.get('/api/forum/posts?category=general');
  assert.equal(seen.body.posts[0].authorAvatar, PNG,
    'cititorul vede poza autorului, nu pe a lui');
});

test('un membru, un arbitru si un partener pot posta, si sunt numiti corect', async () => {
  // The author name is coalesced across four subtype tables. An
  // implementation that only joined clubs would pass every test above
  // and leave three roles anonymous.
  const m = h.client(); await m.register('member', 'fm@test.ro', { fullName: 'Un Membru' });
  const j = h.client(); await j.register('judge', 'fj@test.ro', { fullName: 'Un Arbitru' });
  const p = h.client(); await p.register('partner', 'fp@test.ro', { contactName: 'Un Partener', partnerType: 'sponsor' });

  await m.post('/api/forum/posts', { category: 'robotics', title: 'De la membru' });
  await j.post('/api/forum/posts', { category: 'robotics', title: 'De la arbitru' });
  await p.post('/api/forum/posts', { category: 'robotics', title: 'De la partener' });

  const list = (await m.get('/api/forum/posts?category=robotics')).body.posts;
  const byTitle = {};
  list.forEach(function (x) { byTitle[x.title] = x; });
  assert.equal(byTitle['De la membru'].authorName, 'Un Membru');
  assert.equal(byTitle['De la arbitru'].authorName, 'Un Arbitru');
  assert.equal(byTitle['De la partener'].authorName, 'Un Partener');
});

// ---------------------------------------------------------------------
// What changed: no guests, authorship by id
// ---------------------------------------------------------------------
test('un vizitator nesemnat nu poate posta', async () => {
  const anon = h.client();
  assert.equal((await anon.post('/api/forum/posts', { category: 'general', title: 'Ca oaspete' })).status, 401);
  assert.equal((await anon.post('/api/forum/posts/1/comments', { body: 'x' })).status, 401);
});

test('doua conturi cu acelasi nume afisat nu se pot edita reciproc', async () => {
  // This is what authorship-by-name meant. Club names are unique, so
  // two MEMBERS with the same full name make the point: nothing stops
  // two people being called Ion Popescu.
  const a = h.client(); const accA = await a.register('member', 'ion1@test.ro', { fullName: 'Ion Popescu' });
  const b = h.client(); const accB = await b.register('member', 'ion2@test.ro', { fullName: 'Ion Popescu' });

  const p = await a.post('/api/forum/posts', { category: 'general', title: 'Al lui Ion' });
  assert.notEqual(accA.id, accB.id);

  const stolen = await b.patch('/api/forum/posts/' + p.body.post.id, { title: 'Acum e al meu' });
  assert.equal(stolen.status, 404, 'acelasi nume nu inseamna acelasi cont');

  const still = await h.sql('SELECT title FROM oltp.forum_posts WHERE post_id = $1', [p.body.post.id]);
  assert.equal(still.rows[0].title, 'Al lui Ion');
});

// ---------------------------------------------------------------------
// Announcements
// ---------------------------------------------------------------------
test('un club nu poate publica anunturi', async () => {
  const A = await club('ann1@test.ro', 'Clubul Anunt');
  const r = await A.post('/api/forum/posts', { category: 'announcements', title: 'Anunț fals' });
  assert.equal(r.status, 403);
  assert.match(r.body.error, /organizator/i);
});

test('un arbitru poate publica anunturi', async () => {
  // The control. Without it, an implementation refusing announcements
  // to everyone would pass the test above.
  const j = h.client();
  await j.register('judge', 'ann2@test.ro', { fullName: 'Organizator' });
  const r = await j.post('/api/forum/posts', { category: 'announcements', title: 'Program actualizat' });
  assert.equal(r.status, 201, JSON.stringify(r.body));

  const anon = h.client();
  const seen = await anon.get('/api/forum/posts?category=announcements');
  assert.equal(seen.body.posts.length, 1);
});

test('o categorie inexistenta este refuzata', async () => {
  const A = await club('cat@test.ro', 'Clubul Cat');
  const r = await A.post('/api/forum/posts', { category: 'inexistenta', title: 'X' });
  assert.equal(r.status, 400);
});

// ---------------------------------------------------------------------
// Editing and deleting
// ---------------------------------------------------------------------
test('autorul isi editeaza postarea, si ea este marcata ca editata', async () => {
  const A = await club('ed1@test.ro', 'Clubul Ed');
  const p = await A.post('/api/forum/posts', { category: 'general', title: 'Titlu', body: 'Corp' });

  const r = await A.patch('/api/forum/posts/' + p.body.post.id, { title: 'Titlu nou' });
  assert.equal(r.status, 200, JSON.stringify(r.body));

  const seen = (await A.get('/api/forum/posts?category=general')).body.posts[0];
  assert.equal(seen.title, 'Titlu nou');
  assert.ok(seen.editedAt, 'editedAt este de unde se desenează "(edited)"');
});

test('o postare stearsa isi pastreaza locul si isi pierde continutul', async () => {
  // Not a DELETE: forum_comments.parent_comment_id means a removed post
  // would leave replies to nothing.
  const A = await club('del1@test.ro', 'Clubul Del');
  const B = await club('del2@test.ro', 'Clubul Del2');
  const p = await A.post('/api/forum/posts', { category: 'general', title: 'De șters', body: 'Conținut' });
  await B.post('/api/forum/posts/' + p.body.post.id + '/comments', { body: 'Un răspuns.' });

  assert.equal((await A.del('/api/forum/posts/' + p.body.post.id)).status, 200);

  const seen = (await B.get('/api/forum/posts?category=general')).body.posts[0];
  assert.equal(seen.isDeleted, true);
  assert.equal(seen.body, null, 'continutul nu mai este servit');

  const rows = await h.sql('SELECT count(*)::int AS n FROM oltp.forum_comments WHERE post_id = $1', [p.body.post.id]);
  assert.equal(rows.rows[0].n, 1, 'raspunsul exista in continuare');
});

test('nu se poate raspunde la o postare stearsa', async () => {
  const A = await club('del3@test.ro', 'Clubul Del3');
  const B = await club('del4@test.ro', 'Clubul Del4');
  const p = await A.post('/api/forum/posts', { category: 'general', title: 'Închis' });
  await A.del('/api/forum/posts/' + p.body.post.id);

  const r = await B.post('/api/forum/posts/' + p.body.post.id + '/comments', { body: 'Târziu.' });
  assert.equal(r.status, 404, 'altfel raspunsul ar ateriza undeva unde nu il vede nimeni');
});

test('altcineva nu poate sterge o postare', async () => {
  const A = await club('del5@test.ro', 'Clubul Del5');
  const B = await club('del6@test.ro', 'Clubul Del6');
  const p = await A.post('/api/forum/posts', { category: 'general', title: 'A mea' });

  assert.equal((await B.del('/api/forum/posts/' + p.body.post.id)).status, 404);
  const still = await h.sql('SELECT is_deleted FROM oltp.forum_posts WHERE post_id = $1', [p.body.post.id]);
  assert.equal(still.rows[0].is_deleted, false);
});

test('un raspuns sters isi pastreaza locul in fir', async () => {
  const A = await club('delc1@test.ro', 'Clubul C1');
  const B = await club('delc2@test.ro', 'Clubul C2');
  const p = await A.post('/api/forum/posts', { category: 'general', title: 'Fir' });
  const c = await B.post('/api/forum/posts/' + p.body.post.id + '/comments', { body: 'Primul.' });

  assert.equal((await B.del('/api/forum/comments/' + c.body.comment.id)).status, 200);

  const comments = (await A.get('/api/forum/posts/' + p.body.post.id + '/comments')).body.comments;
  assert.equal(comments.length, 1, 'randul ramane, ca sa nu devina raspunsurile la el orfane');
  assert.equal(comments[0].isDeleted, true);
  assert.equal(comments[0].body, null);
});

test('titlul si corpul raspunsului nu pot fi goale', async () => {
  const A = await club('gol@test.ro', 'Clubul Gol');
  assert.equal((await A.post('/api/forum/posts', { category: 'general', title: '   ' })).status, 400);
  const p = await A.post('/api/forum/posts', { category: 'general', title: 'Titlu' });
  assert.equal((await A.post('/api/forum/posts/' + p.body.post.id + '/comments', { body: '  ' })).status, 400);
});

test('filtrarea pe categorie chiar filtreaza', async () => {
  const A = await club('filt@test.ro', 'Clubul Filtru');
  await A.post('/api/forum/posts', { category: 'general', title: 'În general' });
  await A.post('/api/forum/posts', { category: 'design', title: 'În design' });

  const g = (await A.get('/api/forum/posts?category=general')).body.posts;
  assert.equal(g.length, 1);
  assert.equal(g[0].title, 'În general');

  const all = (await A.get('/api/forum/posts')).body.posts;
  assert.equal(all.length, 2, 'fara categorie inseamna tot');
});
