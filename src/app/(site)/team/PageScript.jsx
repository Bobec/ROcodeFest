"use client";
// The behaviour this page carried as inline <script> blocks, moved here
// unchanged apart from the links (x.html -> /x). It runs once, after
// React has hydrated the markup in page.tsx, and works on that DOM by id.
//
// It is the next thing to rewrite as React state, one page at a time;
// until then it keeps the page doing exactly what it did before.
import { useEffect } from "react";

let started = false;

export default function TeamScript() {
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
  // One team's page
  // =================================================================
  // This page rendered entirely from mock data: a made-up category and
  // city, two invented submissions, two invented join requests, two
  // invented members. Accept, Decline, Add, Remove and Delete all
  // rearranged those arrays in memory and wrote nothing anywhere.
  //
  // It was also addressed by NAME -- /team?club=X&team=Y -- which
  // cannot identify a team: two clubs may have teams called the same
  // thing, and a rename breaks every link. It takes ?id= now, and the
  // four pages that link here were changed to match.

  function esc(s){ return String(s == null ? '' : s).replace(/</g, '&lt;'); }

  function api(path, options){
    var opts = options || {};
    opts.credentials = 'same-origin';
    if(opts.body){ opts.headers = { 'Content-Type': 'application/json' }; opts.body = JSON.stringify(opts.body); }
    return fetch(path, opts).then(function(r){
      return r.json().catch(function(){ return {}; })
        .then(function(d){ return { ok: r.ok, status: r.status, d: d }; });
    });
  }

  var params = new URLSearchParams(window.location.search);
  var teamId = params.get('id');

  var me = null, team = null, members = [], requests = [], subs = [];

  function load(){
    return Promise.all([
      api('/auth/me').then(function(r){ me = (r.d && r.d.account) || null; }),
      api('/api/teams').then(function(r){
        var all = (r.d && r.d.teams) || [];
        team = all.filter(function(t){ return String(t.id) === String(teamId); })[0] || null;
      })
    ]).then(function(){
      if(!team) return;
      // Members are public -- this is a page about a team, and who is on
      // it is the first thing anyone wants to know.
      return api('/api/memberships?teamId=' + encodeURIComponent(team.id))
        .then(function(r){ members = (r.d && r.d.members) || []; });
    });
  }

  // These two are scoped to the caller by the server, so they simply
  // come back empty for anyone who may not see them. No role check here
  // decides what is fetched -- the server does.
  function loadPrivate(){
    return Promise.all([
      api('/api/join-requests/incoming')
        .then(function(r){
          requests = ((r.d && r.d.requests) || []).filter(function(q){
            return String(q.teamId) === String(team.id) && q.status === 'pending';
          });
        })
        .catch(function(){ requests = []; }),
      api('/api/submissions')
        .then(function(r){
          subs = ((r.d && r.d.submissions) || []).filter(function(s){
            return String(s.teamId) === String(team.id);
          });
        })
        .catch(function(){ subs = []; })
    ]);
  }

  function renderHero(){
    var catEl = document.getElementById('th-cat');
    catEl.textContent = team.categoryLabel || team.category;
    catEl.className = 'team-cat-badge cat-' + (team.categoryLabel || 'Other');
    document.getElementById('th-name').textContent = team.teamName;
    document.getElementById('th-club-line').textContent =
      team.clubName + (team.clubCity ? ' · ' + team.clubCity : '') +
      ' · cod ' + team.participationCode;

    var rolePill = document.getElementById('th-role-pill');
    if(role === 'club'){
      rolePill.textContent = 'Administrezi această echipă';
      rolePill.style.display = 'inline-block';
    } else if(role === 'member'){
      rolePill.textContent = 'Faci parte din această echipă';
      rolePill.classList.add('member-role');
      rolePill.style.display = 'inline-block';
    }

    // The four-stage track that stood here was driven by a made-up
    // number. There is no definition yet of what makes a team reach a
    // stage, so the space shows what is true instead: how full the team
    // is against its category's limit.
    document.getElementById('th-progress').innerHTML =
      '<p style="font-size:13px; color:var(--ink-soft); margin:0;">' +
      members.length + ' din ' + team.maxMembers + ' locuri ocupate' +
      '</p>';
  }

  function renderSubs(){
    var wrap = document.getElementById('subs-list');
    var emptyMsg = document.getElementById('subs-empty');
    wrap.innerHTML = '';
    if(subs.length === 0){ emptyMsg.style.display = 'block'; return; }
    emptyMsg.style.display = 'none';
    subs.forEach(function(s){
      var authorTag = s.authorRole === 'club'
        ? '<span class="author-tag club-tag">Club</span>'
        : '<span class="author-tag">de ' + esc(s.authorName) + '</span>';
      var row = document.createElement('div');
      row.className = 'sub-item';
      row.innerHTML = '<strong></strong> <span class="sub-status">Trimisă</span>' + authorTag +
        '<br><span style="font-size:12px;color:var(--ink-soft);"></span>';
      row.querySelector('strong').textContent = s.title;
      row.querySelectorAll('span')[1].textContent =
        s.challengeName + ' · v' + s.version + ' · ' + new Date(s.createdAt).toLocaleDateString();
      wrap.appendChild(row);
    });
  }

  function renderRequests(){
    var wrap = document.getElementById('requests-list');
    var emptyMsg = document.getElementById('no-requests');
    wrap.innerHTML = '';
    if(requests.length === 0){ emptyMsg.style.display = 'block'; return; }
    emptyMsg.style.display = 'none';

    requests.forEach(function(r){
      var row = document.createElement('div');
      row.className = 'req-row';
      row.innerHTML =
        '<div class="req-info"><div class="r-name"></div><div class="r-meta"></div></div>' +
        '<div class="req-actions"><button class="accept-btn">Acceptă</button><button class="decline-btn">Refuză</button></div>';
      row.querySelector('.r-name').textContent = r.memberName;
      row.querySelector('.r-meta').textContent =
        (r.memberCity || '—') + ' · ' + r.memberEmail + (r.message ? ' · "' + r.message + '"' : '');

      // Accepting is one call that marks the request AND creates the
      // membership in one transaction. It used to push a name onto an
      // array and splice another.
      function decide(verb, btn){
        btn.disabled = true;
        api('/api/join-requests/' + r.id + '/' + verb, { method: 'POST' })
          .then(function(res){
            if(!res.ok){
              btn.disabled = false;
              row.querySelector('.r-meta').textContent = res.d.error || 'Nu a mers.';
              return;
            }
            return refresh();
          })
          .catch(function(){ btn.disabled = false; });
      }
      var acc = row.querySelector('.accept-btn');
      var dec = row.querySelector('.decline-btn');
      acc.addEventListener('click', function(){ decide('accept', acc); });
      dec.addEventListener('click', function(){ decide('reject', dec); });

      wrap.appendChild(row);
    });
  }

  function renderMembers(){
    var wrap = document.getElementById('members-list');
    var emptyMsg = document.getElementById('no-members');
    wrap.innerHTML = '';
    if(members.length === 0){ emptyMsg.style.display = 'block'; return; }
    emptyMsg.style.display = 'none';

    members.forEach(function(m){
      var row = document.createElement('div');
      row.className = 'member-row';
      row.innerHTML = '<div><div class="m-name"></div><div class="m-role"></div></div>' +
        (role === 'club' ? '<button class="remove-btn">Elimină</button>' : '');
      row.querySelector('.m-name').textContent = m.memberName;
      row.querySelector('.m-role').textContent =
        (m.roleTitle || 'membru') + (m.memberCity ? ' · ' + m.memberCity : '');

      var rm = row.querySelector('.remove-btn');
      if(rm){
        // Ending a membership sets left_at; it does not delete the row.
        // Scores, submissions and forum posts from that season were made
        // by someone who was on the team at the time.
        rm.addEventListener('click', function(){
          rm.disabled = true;
          api('/api/memberships/' + m.id, { method: 'DELETE' })
            .then(function(res){
              if(!res.ok){ rm.disabled = false; alert(res.d.error || 'Nu s-a putut scoate.'); return; }
              return refresh();
            })
            .catch(function(){ rm.disabled = false; });
        });
      }
      wrap.appendChild(row);
    });
  }

  var role = null;

  function refresh(){
    return load().then(function(){
      if(!team) return;
      return (role ? loadPrivate() : Promise.resolve()).then(function(){
        renderHero(); renderMembers(); renderRequests(); renderSubs();
      });
    });
  }

  load().then(function(){
    if(!team){
      document.getElementById('team-content').style.display = 'block';
      document.getElementById('th-name').textContent = 'Echipa nu a fost găsită';
      document.getElementById('th-club-line').textContent =
        teamId ? 'Linkul poate fi vechi — echipele se caută după id acum.' : 'Lipsește ?id= din adresă.';
      document.getElementById('no-access-banner').style.display = 'block';
      return;
    }

    // Which role the VIEWER has on THIS team, not "any club is treated
    // as the owner" as before. A club that is not this team's club sees
    // the page as a visitor, which is what it is to them.
    if(me && me.role === 'club' && String(me.id) === String(team.clubId)) role = 'club';
    else if(me && me.role === 'member') role = 'member';

    document.getElementById('team-content').style.display = 'block';
    var back = document.getElementById('back-link');
    back.href = role === 'club' ? '/profile'
              : (role === 'member' ? '/member-profile' : '/founding-teams');
    back.textContent = role === 'club' ? '← Înapoi la club'
              : (role === 'member' ? '← Înapoi la profil' : '← Înapoi la echipe');

    document.getElementById('subs-manage-link').href =
      '/submissions?team=' + encodeURIComponent(team.teamName);

    if(!role){
      renderHero();
      renderMembers();
      document.getElementById('no-access-banner').style.display = 'block';
      return;
    }

    document.getElementById('manage-wrap').style.display = 'block';
    if(role === 'club'){ document.getElementById('danger-zone').style.display = 'block'; }

    return loadPrivate().then(function(){
      renderHero(); renderMembers(); renderRequests(); renderSubs();
    });
  });

  // The "Add member" row is gone for the same reason it went from
  // /profile: a typed-in name is not an account, so the person named
  // could not sign in, submit, or appear anywhere else. A team is filled
  // by accepting the requests above.

  if(document.getElementById('delete-team-btn')){
    document.getElementById('delete-team-btn').addEventListener('click', function(){
      // Not built on the server, and saying so beats a button that
      // announces success and changes nothing -- which is what this one
      // used to do. A team carries scores, submissions and memberships,
      // so removing one needs a decision about what happens to them.
      alert('Retragerea unei echipe nu este încă disponibilă. Scrie-ne și o facem manual.');
    });
  }
});
}
