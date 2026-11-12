'use strict';
const express = require('express');
const session = require('express-session');
const db = require('./db');

const app = express();
// 4000, because the site (Next.js, `npm run dev` at the repository root)
// takes 3000 and forwards /auth/* and /api/* here -- see next.config.ts.
const PORT = Number(process.env.PORT || 4000);

app.set('trust proxy', 1);
app.use(express.json({ limit: '256kb' }));

// The pages used to be served by this process, straight from the
// repository root. They are a Next.js app now. In development it proxies
// /api/* and /auth/* to this server; on Vercel, vercel.json routes them to
// this app as a function. Either way the browser sees a single origin, so
// the session cookie needs no CORS negotiation and no SameSite exception.

if (!process.env.SESSION_SECRET && process.env.NODE_ENV === 'production') {
  console.error('SESSION_SECRET is required in production. Refusing to start.');
  process.exit(1);
}

// ---------------------------------------------------------------------
// Sessions live in the database, not in this process
// ---------------------------------------------------------------------
// express-session's default store keeps them in memory, which has three
// consequences and none of them are exotic:
//
//   * every restart signs everybody out -- so every deploy would
//   * two instances cannot share a session, so a request landing on the
//     wrong one arrives as a stranger
//   * memory grows with the number of sessions and nothing prunes it
//
// The store reuses the pool from db.js rather than opening its own.
// Sessions are read on every single request, so a second pool would
// double the connections this process holds for no benefit.
//
// app.session is created by db/00_app_schema.sql for a fresh database
// and by db/migrations/0001_session_store.sql for one that already has
// data. createTableIfMissing is deliberately NOT used: a table appearing
// as a side effect of a process starting is a schema change nobody
// reviewed, and it would be invisible to the migration bookkeeping.
const pgSession = require('connect-pg-simple')(session);

app.use(session({
  store: new pgSession({
    pool: db.pool,
    schemaName: 'app',
    tableName: 'session',
    // Sweep expired rows every 15 minutes. The default is every minute,
    // which is a lot of writes for a table that will hold hundreds of
    // rows, and the sweep is not what keeps an expired session from
    // being honoured -- the store checks expire on read.
    pruneSessionInterval: 60 * 15,
  }),
  name: 'rocodefest.sid',
  secret: process.env.SESSION_SECRET || 'dev-only-not-a-secret',
  resave: false,
  saveUninitialized: false,          // no cookie until someone signs in
  cookie: {
    httpOnly: true,                  // page scripts cannot read it
    sameSite: 'lax',
    secure: process.env.NODE_ENV === 'production',
    maxAge: 1000 * 60 * 60 * 8,      // a festival day
  },
}));

app.use('/auth',        require('./routes/auth'));
app.use('/api/clubs',   require('./routes/clubs'));
app.use('/api/teams',   require('./routes/teams'));
app.use('/api/me',      require('./routes/me'));
app.use('/api/stats',   require('./routes/stats'));
app.use('/api/join-requests', require('./routes/joinRequests'));
app.use('/api/memberships',   require('./routes/memberships'));
app.use('/api/submissions',   require('./routes/submissions'));
app.use('/api/appeals',       require('./routes/appeals'));
app.use('/api/scores',        require('./routes/scores'));
app.use('/api/forum',         require('./routes/forum'));
app.use('/api/leaderboard',   require('./routes/leaderboard'));
app.use('/api/news',          require('./routes/news'));
app.use('/api/schedule',      require('./routes/schedule'));
app.use('/api/certificates',  require('./routes/certificates'));
// Everything an organiser runs the festival with. The role guard is
// applied once inside the router, at its mount, rather than per route.
app.use('/api/admin',         require('./routes/admin'));

// Readiness, not liveness: it answers whether the database is reachable,
// because a process that is up but cannot query is not serving anything.
app.get('/api/health', async (req, res) => {
  try {
    const r = await db.query('SELECT count(*)::int AS clubs FROM clubs');
    res.json({ ok: true, clubs: r.rows[0].clubs });
  } catch (e) {
    res.status(503).json({ ok: false, error: 'baza de date nu răspunde' });
  }
});

app.use('/api', (req, res) => res.status(404).json({ error: 'Endpoint inexistent.' }));

// Last resort. Anything that reaches here is a bug rather than a rejected
// request, so it is logged in full and answered with nothing: an internal
// message repeated to the browser is how table names and query fragments
// end up in screenshots.
app.use((err, req, res, next) => {
  console.error(`[${req.method} ${req.path}]`, err);
  res.status(500).json({ error: 'Eroare internă.' });
});

// Only bind a port when this file is RUN, not when it is imported. The
// tests need the app object to listen on an ephemeral port of their own;
// without this guard, importing it would take port 3000 and two test
// files could not run at once.
if (require.main === module) {
  app.listen(PORT, () => {
    console.log(`ROcodeFest pe http://localhost:${PORT}`);
    console.log(`  baza de date: ${process.env.PGDATABASE || 'rocodefest'}@${process.env.PGHOST || 'localhost'}`);
  });
}

module.exports = app;
