"use client";
// The behaviour this page carried as inline <script> blocks, moved here
// unchanged apart from the links (x.html -> /x). It runs once, after
// React has hydrated the markup in page.tsx, and works on that DOM by id.
//
// It is the next thing to rewrite as React state, one page at a time;
// until then it keeps the page doing exactly what it did before.
import { useEffect } from "react";

let started = false;

export default function SubmissionsScript() {
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







  // Who is signed in comes from the server. These used to be
  // localStorage keys, which is where three findings came from: a
  // role whose key no navigation bar read, a key nothing cleared,
  // and two keys where one sign-out cleared one. There is one
  // session now and it carries its own role.
  // /api/teams/mine answers for both roles: a club gets the teams it
  // owns, a member gets the teams it currently belongs to. This page
  // used to work both out in the browser -- the club by filtering the
  // full list on its own name, and the member by reading the join
  // requests and keeping the accepted ones. An accepted request is not
  // a membership; a member removed from a team still had one, and could
  // still pick that team here.
  Promise.all([
    fetch('/auth/me',        { credentials: 'same-origin' }).then(function(r){ return r.json(); }),
    fetch('/api/teams/mine', { credentials: 'same-origin' })
      .then(function(r){ return r.ok ? r.json() : { teams: [] }; })
  ])
    .then(function(res){
    var d = res[0];
    var myTeams = (res[1] && res[1].teams) || [];
    var a = d && d.account;
    var clubSession = (a && a.role === 'club') ? { clubName: a.clubName, number: a.foundingNumber } : null;
    var memberSession = (a && a.role === 'member') ? { memberName: a.fullName, email: a.email, city: a.city } : null;

  var role = clubSession ? 'club' : (memberSession ? 'member' : null);

  if(!role){ document.getElementById('no-club').style.display = 'block'; }
  else {
    document.getElementById('sub-wrap').style.display = 'block';
    var sel = document.getElementById('sub-team');
    var myTeamOptions = []; // {teamName, clubName, category}

    if(role === 'club'){
      document.getElementById('sub-session-line').innerHTML = 'Trimiți ca club <strong>' + clubSession.clubName.replace(/</g,'&lt;') + '</strong>. Ca club, poți vedea și gestiona toate lucrările echipelor tale.';
      document.getElementById('sub-list-hint').textContent = 'Toate lucrările trimise de echipele clubului tău.';
      myTeamOptions = myTeams.map(function(t){ return { id:t.id, teamName:t.teamName, clubName:t.clubName, category:t.category }; });
    } else {
      document.getElementById('sub-session-line').innerHTML = 'Trimiți ca membru <strong>' + memberSession.memberName.replace(/</g,'&lt;') + '</strong>. Membrii pot trimite lucrări pentru echipele lor și pot edita sau șterge doar ce au trimis personal.';
      document.getElementById('sub-list-hint').textContent = 'Lucrările trimise personal de tine, în oricare dintre echipele tale.';
      myTeamOptions = myTeams.map(function(t){ return { id:t.id, teamName:t.teamName, clubName:t.clubName, category:t.category }; });
    }

    myTeamOptions.forEach(function(t){
      var o = document.createElement('option');
      // The id, not the name. The name went into the request before,
      // and the server has no way to tell two teams called the same
      // thing apart -- nor should it have to.
      o.value = t.id;
      o.setAttribute('data-club', t.clubName);
      o.textContent = t.teamName + ' (' + t.category + ')';
      sel.appendChild(o);
    });

    // Preselect team from ?team= query param (e.g. linked from a team page)
    var qTeam = new URLSearchParams(window.location.search).get('team');
    if(qTeam){
      var match = myTeamOptions.filter(function(t){ return t.teamName === qTeam; })[0];
      if(match){ sel.value = match.id; }
    }

    // Which challenge this submission answers. challenge_id is NOT NULL
    // and this page had no picker at all, so nothing it produced could
    // ever have become a row.
    var chSel = document.getElementById('sub-challenge');

    function loadChallenges(){
      chSel.innerHTML = '';
      if(!sel.value){ return Promise.resolve(); }
      return fetch('/api/submissions/challenges?teamId=' + encodeURIComponent(sel.value),
                   { credentials: 'same-origin' })
        .then(function(r){ return r.ok ? r.json() : { challenges: [] }; })
        .then(function(d){
          var list = (d && d.challenges) || [];
          if(list.length === 0){
            var none = document.createElement('option');
            none.value = '';
            none.textContent = 'Nicio probă deschisă în sezonul activ';
            chSel.appendChild(none);
            return;
          }
          list.forEach(function(c){
            var o = document.createElement('option');
            o.value = c.id;
            // Shown rather than hidden: a team that missed a deadline
            // needs to see what it missed.
            o.textContent = c.name + (c.closed ? ' (termen depășit)' : '');
            o.disabled = c.closed;
            chSel.appendChild(o);
          });
        })
        .catch(function(){});
    }

    sel.addEventListener('change', loadChallenges);

    // The submissions themselves
    var subs = [];
    function loadSubs(){
      return fetch('/api/submissions', { credentials: 'same-origin' })
        .then(function(r){ return r.ok ? r.json() : { submissions: [] }; })
        .then(function(d){ subs = (d && d.submissions) || []; })
        .catch(function(){ subs = []; });
    }

    // The server decides this too -- PATCH and DELETE are scoped in
    // their WHERE clause. This only decides whether to DRAW the
    // buttons, so someone is not offered a control that answers 404.
    function canManage(s){
      if(role === 'club'){ return true; }   // the listing is already only my club's
      return String(s.authorId) === String(a.id);
    }

    function renderSubs(){
      var wrap = document.getElementById('sub-list');
      if(subs.length === 0){ wrap.innerHTML = '<div class="empty-state">Nicio lucrare încă.</div>'; return; }
      // Already newest-first from the query.
      wrap.innerHTML = '<div class="card">' + subs.map(function(s){
        var authorTag = s.authorRole === 'club'
          ? '<span class="author-tag club-tag">Club</span>'
          : '<span class="author-tag">de ' + (s.authorName || 'member').replace(/</g,'&lt;') + '</span>';
        var actions = canManage(s)
          ? '<div class="sub-actions"><button class="link-btn" data-act="edit" data-id="' + s.id + '">Editează</button><button class="link-btn danger" data-act="delete" data-id="' + s.id + '">Șterge</button></div>'
          : '';
        var version = s.version > 1 ? ' <span class="author-tag">v' + s.version + '</span>' : '';
        return '<div class="sub-item" data-item-id="' + s.id + '"><strong>' + s.title.replace(/</g,'&lt;') + '</strong> <span class="sub-status status-submitted">Trimisă</span>' + authorTag + version + '<br><span style="font-size:12px;color:var(--ink-soft);">' + s.teamName.replace(/</g,'&lt;') + ' &middot; ' + s.challengeName.replace(/</g,'&lt;') + ' &middot; ' + new Date(s.createdAt).toLocaleDateString() + '</span>' + (s.description ? '<p style="font-size:13px;margin:6px 0 0;">' + s.description.replace(/</g,'&lt;') + '</p>' : '') + (s.linkUrl ? '<br><a href="' + s.linkUrl.replace(/"/g,'&quot;') + '" style="font-size:12px;color:var(--blue);">' + s.linkUrl.replace(/</g,'&lt;') + '</a>' : '') + actions + '</div>';
      }).join('') + '</div>';

      wrap.querySelectorAll('.link-btn').forEach(function(btn){
        btn.addEventListener('click', function(){
          var id = btn.getAttribute('data-id');
          if(btn.getAttribute('data-act') === 'delete'){
            if(!confirm('Ștergi această lucrare? Acțiunea nu poate fi anulată.')) return;
            fetch('/api/submissions/' + id, { method: 'DELETE', credentials: 'same-origin' })
              .then(function(r){ return r.json().then(function(dd){ return { ok: r.ok, d: dd }; }); })
              .then(function(rr){
                // Only the latest version of a chain can go, and the
                // server says so rather than the page guessing.
                if(!rr.ok){ alert(rr.d.error || 'Nu s-a putut șterge.'); return; }
                return loadSubs().then(renderSubs);
              })
              .catch(function(){});
          } else {
            openEditForm(id);
          }
        });
      });
    }

    function openEditForm(id){
      var item = wrap_query('[data-item-id="' + id + '"]');
      var s = subs.filter(function(x){ return String(x.id) === String(id); })[0];
      if(!item || !s) return;
      item.insertAdjacentHTML('beforeend',
        '<div class="sub-edit-form">' +
          '<div class="field"><label>Titlu</label><input type="text" class="e-title" value="' + s.title.replace(/"/g,'&quot;') + '"></div>' +
          '<div class="field"><label>Descriere</label><textarea class="e-desc" rows="2">' + (s.description || '') + '</textarea></div>' +
          '<div class="field"><label>Link</label><input type="text" class="e-link" value="' + (s.linkUrl||'').replace(/"/g,'&quot;') + '"></div>' +
          '<p class="error-msg e-err"></p>' +
          '<div style="display:flex; gap:10px;"><button class="btn btn-primary btn-small e-save">Salvează modificările</button><button class="btn btn-secondary btn-small e-cancel">Renunță</button></div>' +
        '</div>');
      item.querySelector('.e-cancel').addEventListener('click', renderSubs);
      item.querySelector('.e-save').addEventListener('click', function(){
        var title = item.querySelector('.e-title').value.trim();
        if(!title) return;
        // Only the three descriptive fields. The team, the challenge
        // and the version are refused by
        // enforce_submission_lineage_immutable, so they are not offered
        // and the refusal never has to happen.
        fetch('/api/submissions/' + id, {
          method: 'PATCH',
          credentials: 'same-origin',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({
            title: title,
            description: item.querySelector('.e-desc').value.trim(),
            linkUrl: item.querySelector('.e-link').value.trim()
          })
        })
          .then(function(r){ return r.json().then(function(dd){ return { ok: r.ok, d: dd }; }); })
          .then(function(rr){
            var err = item.querySelector('.e-err');
            if(!rr.ok){ err.textContent = rr.d.error || 'Nu s-a putut salva.'; err.classList.add('show'); return; }
            return loadSubs().then(renderSubs);
          })
          .catch(function(){});
      });
    }
    function wrap_query(sel2){ return document.getElementById('sub-list').querySelector(sel2); }

    Promise.all([loadSubs(), loadChallenges()]).then(renderSubs);

    var subBtn = document.getElementById('sub-btn');
    subBtn.addEventListener('click', function(){
      var teamId = sel.value;
      var challengeId = chSel.value;
      var title = document.getElementById('sub-title').value.trim();
      var errEl = document.getElementById('sub-error');
      if(!teamId || !challengeId || !title){ errEl.textContent = 'Alege echipa și proba, și dă lucrării un titlu.'; errEl.classList.add('show'); return; }
      errEl.classList.remove('show');

      subBtn.disabled = true;
      // Who is submitting is not sent. The server takes it from the
      // session -- submitted_by_account_id is a bare FK, so the
      // database checks the account exists and never that it has
      // anything to do with the team. That check lives in the API.
      fetch('/api/submissions', {
        method: 'POST',
        credentials: 'same-origin',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          teamId: teamId,
          challengeId: challengeId,
          title: title,
          description: document.getElementById('sub-desc').value.trim(),
          linkUrl: document.getElementById('sub-link').value.trim()
        })
      })
        .then(function(r){ return r.json().then(function(dd){ return { ok: r.ok, d: dd }; }); })
        .then(function(rr){
          subBtn.disabled = false;
          if(!rr.ok){
            // The resubmission gate speaks here: a second version needs
            // a review on the previous one asking for it, and the
            // server's message says so with the numbers in it.
            errEl.textContent = rr.d.error || 'Lucrarea nu a putut fi trimisă.';
            errEl.classList.add('show');
            return;
          }
          document.getElementById('sub-title').value = '';
          document.getElementById('sub-desc').value = '';
          document.getElementById('sub-link').value = '';
          return loadSubs().then(renderSubs);
        })
        .catch(function(){ subBtn.disabled = false; errEl.textContent = 'Serverul nu răspunde.'; errEl.classList.add('show'); });
    });
  }

    })
    .catch(function(){});
});
}
