"use client";
// The behaviour this page carried as inline <script> blocks, moved here
// unchanged apart from the links (x.html -> /x). It runs once, after
// React has hydrated the markup in page.tsx, and works on that DOM by id.
//
// It is the next thing to rewrite as React state, one page at a time;
// until then it keeps the page doing exactly what it did before.
import { useEffect } from "react";

let started = false;

export default function AdminScript() {
  useEffect(() => {
    if (started) return;
    started = true;
    run();
  }, []);
  return null;
}

function run() {
const onReady = (fn) => fn();

onReady(function(){






  // =================================================================
  // The organiser's panel
  // =================================================================
  // Everything here goes through /api/admin, which refuses every route
  // to anyone who is not an organiser. The role check below decides
  // what to DRAW; the server decides what is allowed. Drawing a panel
  // of controls that would all answer 403 helps nobody.

  var me = null;
  var seasons = [], challenges = [], matches = [], judges = [],
      teams = [], categories = [], scheduleItems = [], news = [], organizers = [];

  function api(path, options){
    var opts = options || {};
    opts.credentials = 'same-origin';
    if(opts.body){ opts.headers = { 'Content-Type': 'application/json' }; opts.body = JSON.stringify(opts.body); }
    return fetch(path, opts).then(function(r){
      return r.json().catch(function(){ return {}; })
        .then(function(d){ return { ok: r.ok, status: r.status, d: d }; });
    });
  }

  function esc(s){ return String(s == null ? '' : s).replace(/</g, '&lt;'); }

  function fail(id, msg){
    var el = document.getElementById(id);
    el.textContent = msg;
    el.classList.add('show');
  }
  function clearFail(id){ document.getElementById(id).classList.remove('show'); }

  // Dates arrive as ISO strings and are shown in the reader's own zone.
  // A festival runs in one place, but an organiser abroad setting a time
  // needs to see what they set, not what a server thought.
  function when(iso){
    if(!iso) return '—';
    var d = new Date(iso);
    return d.toLocaleDateString() + ' ' + d.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
  }
  function day(iso){ return iso ? new Date(iso).toLocaleDateString() : '—'; }

  // <input type="datetime-local"> gives a local string with no zone, and
  // new Date() reads that as local time -- which is what the organiser
  // meant. toISOString then hands the server a real instant.
  function toIso(value){ return value ? new Date(value).toISOString() : null; }

  var STATUS_LABEL = {
    scheduled: 'programat', in_progress: 'în desfășurare',
    completed: 'încheiat', cancelled: 'anulat'
  };
  var STATUS_COLOR = {
    scheduled: 'var(--ink-soft)', in_progress: 'var(--blue)',
    completed: 'var(--green)', cancelled: 'var(--coral-dark)'
  };

  // ---------------------------------------------------------------
  // Loading
  // ---------------------------------------------------------------
  function loadAll(){
    return Promise.all([
      api('/api/admin/seasons').then(function(r){ seasons = (r.d && r.d.seasons) || []; }),
      api('/api/admin/challenges').then(function(r){ challenges = (r.d && r.d.challenges) || []; }),
      api('/api/admin/matches').then(function(r){ matches = (r.d && r.d.matches) || []; }),
      api('/api/admin/judges').then(function(r){ judges = (r.d && r.d.judges) || []; }),
      api('/api/admin/organizers').then(function(r){ organizers = (r.d && r.d.organizers) || []; }),
      api('/api/teams').then(function(r){ teams = (r.d && r.d.teams) || []; }),
      api('/api/teams/categories').then(function(r){ categories = (r.d && r.d.categories) || []; }),
      api('/api/schedule').then(function(r){ scheduleItems = (r.d && r.d.items) || []; }),
      api('/api/news').then(function(r){ news = (r.d && r.d.news) || []; })
    ]);
  }

  function renderAll(){
    renderSeasons(); renderChallenges(); renderMatches();
    renderSchedule(); renderNews(); renderOrganizers();
    fillPickers();
  }

  function fillPickers(){
    var chSeason = document.getElementById('ch-season');
    chSeason.innerHTML = seasons.map(function(s){
      return '<option value="' + s.id + '"' + (s.isActive ? ' selected' : '') + '>' +
             esc(s.name) + (s.isActive ? ' (activ)' : '') + '</option>';
    }).join('') || '<option value="">Creează întâi un sezon</option>';

    var chCat = document.getElementById('ch-category');
    chCat.innerHTML = '<option value="">— toate categoriile —</option>' +
      categories.map(function(c){ return '<option value="' + c.id + '">' + esc(c.label) + '</option>'; }).join('');

    var maCh = document.getElementById('ma-challenge');
    maCh.innerHTML = challenges.map(function(c){
      return '<option value="' + c.id + '">' + esc(c.name) + ' — ' + esc(c.seasonName) + '</option>';
    }).join('') || '<option value="">Creează întâi o probă</option>';
  }

  // ---------------------------------------------------------------
  // Seasons
  // ---------------------------------------------------------------
  function renderSeasons(){
    var wrap = document.getElementById('seasons-list');
    if(seasons.length === 0){ wrap.innerHTML = '<div class="empty-state">Niciun sezon încă.</div>'; return; }
    wrap.innerHTML = seasons.map(function(s){
      return '<div class="card-light adm-row">' +
        '<div><strong>' + esc(s.name) + '</strong>' +
          (s.isActive ? ' <span class="tag" style="background:var(--green);">activ</span>' : '') +
          '<br><span class="adm-meta">' + day(s.startDate) + ' – ' + day(s.endDate) +
          ' · ' + s.challengeCount + ' probă/probe</span></div>' +
        '<div>' + (s.isActive ? '' :
          '<button class="btn btn-secondary btn-small" data-activate="' + s.id + '">Fă-l activ</button>') +
        '</div>' +
      '</div>';
    }).join('');

    wrap.querySelectorAll('[data-activate]').forEach(function(b){
      b.addEventListener('click', function(){
        b.disabled = true;
        api('/api/admin/seasons/' + b.getAttribute('data-activate'), {
          method: 'PATCH', body: { isActive: true }
        }).then(function(r){
          if(!r.ok){ b.disabled = false; alert(r.d.error || 'Nu s-a putut activa.'); return; }
          return loadAll().then(renderAll);
        });
      });
    });
  }

  document.getElementById('se-btn').addEventListener('click', function(){
    clearFail('se-error');
    var name = document.getElementById('se-name').value.trim();
    var start = document.getElementById('se-start').value;
    if(!name || !start) return fail('se-error', 'Numele și data de început sunt obligatorii.');
    api('/api/admin/seasons', { method: 'POST', body: {
      name: name, startDate: start,
      endDate: document.getElementById('se-end').value || null,
      isActive: document.getElementById('se-active').checked
    }}).then(function(r){
      if(!r.ok) return fail('se-error', r.d.error || 'Sezonul nu a putut fi creat.');
      document.getElementById('se-name').value = '';
      return loadAll().then(renderAll);
    });
  });

  // ---------------------------------------------------------------
  // Challenges
  // ---------------------------------------------------------------
  function renderChallenges(){
    var wrap = document.getElementById('challenges-list');
    if(challenges.length === 0){ wrap.innerHTML = '<div class="empty-state">Nicio probă încă.</div>'; return; }
    wrap.innerHTML = challenges.map(function(c){
      return '<div class="card-light adm-row">' +
        '<div><strong>' + esc(c.name) + '</strong>' +
          (c.seasonActive ? '' : ' <span class="tag" style="background:var(--ink-soft);">sezon inactiv</span>') +
          '<br><span class="adm-meta">' + esc(c.seasonName) + ' · ' +
          (c.stage === 'final' ? 'finala' : 'etapa orașului') + ' · ' +
          (c.categoryLabel ? esc(c.categoryLabel) : 'toate categoriile') +
          ' · termen ' + when(c.deadline) +
          ' · ' + c.submissionCount + ' lucrări, ' + c.matchCount + ' meciuri</span></div>' +
      '</div>';
    }).join('');
  }

  document.getElementById('ch-btn').addEventListener('click', function(){
    clearFail('ch-error');
    var seasonId = document.getElementById('ch-season').value;
    var name = document.getElementById('ch-name').value.trim();
    if(!seasonId || !name) return fail('ch-error', 'Sezonul și numele sunt obligatorii.');
    api('/api/admin/challenges', { method: 'POST', body: {
      seasonId: seasonId, name: name,
      stage: document.getElementById('ch-stage').value,
      categoryId: document.getElementById('ch-category').value || null,
      description: document.getElementById('ch-desc').value.trim() || null,
      deadline: toIso(document.getElementById('ch-deadline').value)
    }}).then(function(r){
      if(!r.ok) return fail('ch-error', r.d.error || 'Proba nu a putut fi creată.');
      document.getElementById('ch-name').value = '';
      document.getElementById('ch-desc').value = '';
      return loadAll().then(renderAll);
    });
  });

  // ---------------------------------------------------------------
  // Matches -- the panel that actually runs the contest
  // ---------------------------------------------------------------
  function renderMatches(){
    var wrap = document.getElementById('matches-list');
    if(matches.length === 0){ wrap.innerHTML = '<div class="empty-state">Niciun meci încă.</div>'; return; }

    wrap.innerHTML = matches.map(function(m){
      var teamChips = m.teams.map(function(t){
        return '<span class="chip">' + esc(t.teamName) + ' <span class="adm-meta">(' + esc(t.clubName) + ')</span>' +
          '<button class="chip-x" data-drop-team="' + m.id + ':' + t.id + '" title="Scoate din meci">×</button></span>';
      }).join('') || '<span class="adm-meta">nicio echipă</span>';

      var judgeChips = m.judges.map(function(j){
        return '<span class="chip">' + esc(j.fullName) +
          '<button class="chip-x" data-drop-judge="' + m.id + ':' + j.id + '" title="Scoate din comisie">×</button></span>';
      }).join('') || '<span class="adm-meta">nicio comisie</span>';

      var inMatch = m.teams.map(function(t){ return String(t.id); });
      var onPanel = m.judges.map(function(j){ return String(j.id); });

      var teamOptions = teams.filter(function(t){ return inMatch.indexOf(String(t.id)) === -1; })
        .map(function(t){ return '<option value="' + t.id + '">' + esc(t.teamName) + ' — ' + esc(t.clubName) + '</option>'; }).join('');
      var judgeOptions = judges.filter(function(j){ return onPanel.indexOf(String(j.id)) === -1; })
        .map(function(j){ return '<option value="' + j.id + '">' + esc(j.fullName) + '</option>'; }).join('');

      var statusOptions = ['scheduled','in_progress','completed','cancelled'].map(function(s){
        return '<option value="' + s + '"' + (m.status === s ? ' selected' : '') + '>' + STATUS_LABEL[s] + '</option>';
      }).join('');

      return '<div class="card">' +
        '<div class="adm-row" style="margin-bottom:10px;">' +
          '<div><strong>' + esc(m.roundName || 'Meci #' + m.id) + '</strong>' +
            ' <span class="tag" style="background:' + STATUS_COLOR[m.status] + ';">' + STATUS_LABEL[m.status] + '</span>' +
            '<br><span class="adm-meta">' + esc(m.challengeName) + ' · ' + esc(m.seasonName) +
            ' · ' + when(m.scheduledAt) + (m.location ? ' · ' + esc(m.location) : '') +
            ' · ' + m.scoreCount + ' punctaje</span></div>' +
          '<div><select class="adm-status" data-match="' + m.id + '" style="width:auto;">' + statusOptions + '</select></div>' +
        '</div>' +
        '<div class="adm-sub"><span class="adm-label">Echipe</span>' + teamChips +
          (teamOptions ? '<span class="adm-add"><select data-add-team-sel="' + m.id + '" style="width:auto;"><option value="">— adaugă echipă —</option>' + teamOptions + '</select></span>' : '') +
        '</div>' +
        '<div class="adm-sub"><span class="adm-label">Comisie</span>' + judgeChips +
          (judgeOptions ? '<span class="adm-add"><select data-add-judge-sel="' + m.id + '" style="width:auto;"><option value="">— adaugă arbitru —</option>' + judgeOptions + '</select></span>' : '') +
        '</div>' +
      '</div>';
    }).join('');

    function after(r, msg){
      if(!r.ok){ alert(r.d.error || msg); return; }
      return loadAll().then(renderAll);
    }

    wrap.querySelectorAll('.adm-status').forEach(function(sel){
      sel.addEventListener('change', function(){
        api('/api/admin/matches/' + sel.getAttribute('data-match'), {
          method: 'PATCH', body: { status: sel.value }
        }).then(function(r){ return after(r, 'Starea nu a putut fi schimbată.'); });
      });
    });

    wrap.querySelectorAll('[data-add-team-sel]').forEach(function(sel){
      sel.addEventListener('change', function(){
        if(!sel.value) return;
        api('/api/admin/matches/' + sel.getAttribute('data-add-team-sel') + '/teams', {
          method: 'POST', body: { teamId: sel.value }
        }).then(function(r){ return after(r, 'Echipa nu a putut fi adăugată.'); });
      });
    });

    wrap.querySelectorAll('[data-add-judge-sel]').forEach(function(sel){
      sel.addEventListener('change', function(){
        if(!sel.value) return;
        api('/api/admin/matches/' + sel.getAttribute('data-add-judge-sel') + '/judges', {
          method: 'POST', body: { judgeId: sel.value }
        }).then(function(r){ return after(r, 'Arbitrul nu a putut fi adăugat.'); });
      });
    });

    // Removal is refused once anyone has scored -- both foreign keys
    // cascade, so the delete would take the judging with it. The server
    // says so, and the message names how many scores it found.
    wrap.querySelectorAll('[data-drop-team]').forEach(function(b){
      b.addEventListener('click', function(){
        var p = b.getAttribute('data-drop-team').split(':');
        api('/api/admin/matches/' + p[0] + '/teams/' + p[1], { method: 'DELETE' })
          .then(function(r){ return after(r, 'Echipa nu a putut fi scoasă.'); });
      });
    });
    wrap.querySelectorAll('[data-drop-judge]').forEach(function(b){
      b.addEventListener('click', function(){
        var p = b.getAttribute('data-drop-judge').split(':');
        api('/api/admin/matches/' + p[0] + '/judges/' + p[1], { method: 'DELETE' })
          .then(function(r){ return after(r, 'Arbitrul nu a putut fi scos.'); });
      });
    });
  }

  document.getElementById('ma-btn').addEventListener('click', function(){
    clearFail('ma-error');
    var challengeId = document.getElementById('ma-challenge').value;
    if(!challengeId) return fail('ma-error', 'Alege o probă.');
    api('/api/admin/matches', { method: 'POST', body: {
      challengeId: challengeId,
      roundName: document.getElementById('ma-round').value.trim() || null,
      scheduledAt: toIso(document.getElementById('ma-when').value),
      location: document.getElementById('ma-where').value.trim() || null
    }}).then(function(r){
      if(!r.ok) return fail('ma-error', r.d.error || 'Meciul nu a putut fi creat.');
      document.getElementById('ma-round').value = '';
      return loadAll().then(renderAll);
    });
  });

  // ---------------------------------------------------------------
  // Schedule
  // ---------------------------------------------------------------
  function renderSchedule(){
    var wrap = document.getElementById('schedule-list');
    if(scheduleItems.length === 0){ wrap.innerHTML = '<div class="empty-state">Programul este gol.</div>'; return; }
    wrap.innerHTML = scheduleItems.map(function(it){
      // A match with no schedule row of its own still appears -- it
      // comes straight from matches, and has no id here to delete.
      var removable = it.id
        ? '<button class="btn btn-secondary btn-small" data-drop-item="' + it.id + '">Șterge</button>'
        : '<span class="adm-meta">din meciuri</span>';
      return '<div class="card-light adm-row">' +
        '<div><strong>' + esc(it.title) + '</strong>' +
          ' <span class="tag" style="background:var(--ink-soft);">' + esc(it.kind) + '</span>' +
          '<br><span class="adm-meta">' + when(it.startsAt) +
          (it.endsAt ? ' – ' + when(it.endsAt) : '') +
          (it.location ? ' · ' + esc(it.location) : '') + '</span></div>' +
        '<div>' + removable + '</div>' +
      '</div>';
    }).join('');

    wrap.querySelectorAll('[data-drop-item]').forEach(function(b){
      b.addEventListener('click', function(){
        api('/api/schedule/' + b.getAttribute('data-drop-item'), { method: 'DELETE' })
          .then(function(r){
            if(!r.ok){ alert(r.d.error || 'Nu s-a putut șterge.'); return; }
            return loadAll().then(renderAll);
          });
      });
    });
  }

  document.getElementById('sc-btn').addEventListener('click', function(){
    clearFail('sc-error');
    var active = seasons.filter(function(s){ return s.isActive; })[0];
    if(!active) return fail('sc-error', 'Nu există un sezon activ.');
    var title = document.getElementById('sc-title').value.trim();
    var start = document.getElementById('sc-start').value;
    if(!title || !start) return fail('sc-error', 'Titlul și ora de început sunt obligatorii.');
    api('/api/schedule', { method: 'POST', body: {
      seasonId: active.id,
      kind: document.getElementById('sc-kind').value,
      title: title,
      startsAt: toIso(start),
      endsAt: toIso(document.getElementById('sc-end').value),
      location: document.getElementById('sc-where').value.trim() || null
    }}).then(function(r){
      if(!r.ok) return fail('sc-error', r.d.error || 'Intrarea nu a putut fi adăugată.');
      document.getElementById('sc-title').value = '';
      return loadAll().then(renderAll);
    });
  });

  // ---------------------------------------------------------------
  // News
  // ---------------------------------------------------------------
  function renderNews(){
    var wrap = document.getElementById('news-list');
    if(news.length === 0){ wrap.innerHTML = '<div class="empty-state">Niciun articol încă.</div>'; return; }
    wrap.innerHTML = news.map(function(n){
      return '<div class="card-light adm-row">' +
        '<div><strong>' + esc(n.title) + '</strong>' +
          (n.publishedAt
            ? ' <span class="tag" style="background:var(--green);">publicat</span>'
            : ' <span class="tag" style="background:var(--yellow); color:var(--ink);">ciornă</span>') +
          '<br><span class="adm-meta">' + (n.publishedAt ? when(n.publishedAt) : 'nepublicat') +
          (n.authorName ? ' · ' + esc(n.authorName) : '') + '</span></div>' +
        '<div style="display:flex; gap:8px;">' +
          '<button class="btn btn-secondary btn-small" data-toggle-news="' + n.id + '" data-published="' + (n.publishedAt ? '1' : '0') + '">' +
            (n.publishedAt ? 'Retrage' : 'Publică') + '</button>' +
          '<button class="btn btn-secondary btn-small" data-drop-news="' + n.id + '">Șterge</button>' +
        '</div>' +
      '</div>';
    }).join('');

    wrap.querySelectorAll('[data-toggle-news]').forEach(function(b){
      b.addEventListener('click', function(){
        api('/api/news/' + b.getAttribute('data-toggle-news'), {
          method: 'PATCH', body: { publish: b.getAttribute('data-published') !== '1' }
        }).then(function(r){
          if(!r.ok){ alert(r.d.error || 'Nu s-a putut schimba.'); return; }
          return loadAll().then(renderAll);
        });
      });
    });
    wrap.querySelectorAll('[data-drop-news]').forEach(function(b){
      b.addEventListener('click', function(){
        if(!confirm('Ștergi articolul? Nu se mai poate recupera.')) return;
        api('/api/news/' + b.getAttribute('data-drop-news'), { method: 'DELETE' })
          .then(function(r){
            if(!r.ok){ alert(r.d.error || 'Nu s-a putut șterge.'); return; }
            return loadAll().then(renderAll);
          });
      });
    });
  }

  document.getElementById('nw-btn').addEventListener('click', function(){
    clearFail('nw-error');
    var title = document.getElementById('nw-title').value.trim();
    var body = document.getElementById('nw-body').value.trim();
    if(!title || !body) return fail('nw-error', 'Titlul și textul sunt obligatorii.');
    api('/api/news', { method: 'POST', body: {
      title: title,
      summary: document.getElementById('nw-summary').value.trim() || null,
      body: body,
      publish: document.getElementById('nw-publish').checked
    }}).then(function(r){
      if(!r.ok) return fail('nw-error', r.d.error || 'Articolul nu a putut fi salvat.');
      document.getElementById('nw-title').value = '';
      document.getElementById('nw-summary').value = '';
      document.getElementById('nw-body').value = '';
      return loadAll().then(renderAll);
    });
  });

  // ---------------------------------------------------------------
  // Organisers
  // ---------------------------------------------------------------
  function renderOrganizers(){
    var wrap = document.getElementById('organizers-list');
    if(organizers.length === 0){ wrap.innerHTML = '<div class="empty-state">Niciun organizator.</div>'; return; }
    wrap.innerHTML = organizers.map(function(o){
      return '<div class="card-light adm-row">' +
        '<div><strong>' + esc(o.fullName) + '</strong>' +
          (String(o.id) === String(me.id) ? ' <span class="tag" style="background:var(--blue);">tu</span>' : '') +
          '<br><span class="adm-meta">' + esc(o.email) + (o.title ? ' · ' + esc(o.title) : '') + '</span></div>' +
      '</div>';
    }).join('');
  }

  document.getElementById('og-btn').addEventListener('click', function(){
    clearFail('og-error');
    var name = document.getElementById('og-name').value.trim();
    var email = document.getElementById('og-email').value.trim();
    var pass = document.getElementById('og-password').value;
    if(!name || !email) return fail('og-error', 'Numele și emailul sunt obligatorii.');
    if(pass.length < 8) return fail('og-error', 'Parola trebuie să aibă cel puțin 8 caractere.');
    api('/api/admin/organizers', { method: 'POST', body: {
      fullName: name, email: email, password: pass,
      title: document.getElementById('og-title').value.trim() || null
    }}).then(function(r){
      if(!r.ok) return fail('og-error', r.d.error || 'Contul nu a putut fi creat.');
      document.getElementById('og-name').value = '';
      document.getElementById('og-email').value = '';
      document.getElementById('og-password').value = '';
      document.getElementById('og-title').value = '';
      return loadAll().then(renderAll);
    });
  });

  // ---------------------------------------------------------------
  // Tabs and bootstrap
  // ---------------------------------------------------------------
  document.querySelectorAll('#admin-tabs .tab-btn').forEach(function(btn){
    btn.addEventListener('click', function(){
      document.querySelectorAll('#admin-tabs .tab-btn').forEach(function(b){ b.classList.remove('active'); });
      btn.classList.add('active');
      var want = btn.getAttribute('data-panel');
      document.querySelectorAll('.admin-panel').forEach(function(p){
        p.style.display = (p.id === 'panel-' + want) ? '' : 'none';
      });
    });
  });

  api('/auth/me')
    .then(function(r){
      me = (r.d && r.d.account) || null;
      if(!me || me.role !== 'organizer'){
        document.getElementById('not-organizer').style.display = 'block';
        return;
      }
      document.getElementById('admin-wrap').style.display = 'block';
      document.getElementById('admin-session-line').innerHTML =
        'Conectat ca <strong>' + esc(me.fullName) + '</strong>' +
        (me.title ? ' · ' + esc(me.title) : '');
      return loadAll().then(renderAll);
    })
    .catch(function(){
      document.getElementById('not-organizer').style.display = 'block';
    });

});
}
