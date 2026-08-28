'use strict';
const path = require('path');
const express = require('express');
const session = require('express-session');
const db = require('./db');

const app = express();
const PORT = Number(process.env.PORT || 3000);

app.set('trust proxy', 1);
app.use(express.json({ limit: '256kb' }));

// The pages are served by this same process, from the repository root.
// Same origin means the session cookie needs no CORS negotiation and no
// SameSite exception -- which is also why the pages can keep being plain
// files with no build step.
app.use(express.static(path.join(__dirname, '..'), { extensions: ['html'] }));

if (!process.env.SESSION_SECRET && process.env.NODE_ENV === 'production') {
  console.error('SESSION_SECRET is required in production. Refusing to start.');
  process.exit(1);
}

app.use(session({
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
  // The default store keeps sessions in memory: everyone is signed out
  // when the process restarts, and it does not survive more than one
  // instance. Fine for development, and stated here rather than
  // discovered in production.
}));

app.use('/auth',        require('./routes/auth'));
app.use('/api/clubs',   require('./routes/clubs'));
app.use('/api/teams',   require('./routes/teams'));
app.use('/api/me',      require('./routes/me'));
app.use('/api/stats',   require('./routes/stats'));
app.use('/api/join-requests', require('./routes/joinRequests'));
app.use('/api/memberships',   require('./routes/memberships'));

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
