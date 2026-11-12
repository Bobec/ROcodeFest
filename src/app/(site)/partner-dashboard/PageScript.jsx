"use client";
// The behaviour this page carried as inline <script> blocks, moved here
// unchanged apart from the links (x.html -> /x). It runs once, after
// React has hydrated the markup in page.tsx, and works on that DOM by id.
//
// It is the next thing to rewrite as React state, one page at a time;
// until then it keeps the page doing exactly what it did before.
import { useEffect } from "react";

let started = false;

export default function PartnerDashboardScript() {
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
  // The counts and the team list used to be the .length of localStorage
  // arrays, so a partner opening this dashboard on a clean browser was
  // told the festival had no clubs and no teams. They come from the
  // server now, and all three requests go out together.
  Promise.all([
    fetch('/auth/me',   { credentials: 'same-origin' }).then(function(r){ return r.json(); }),
    fetch('/api/teams', { credentials: 'same-origin' }).then(function(r){ return r.json(); }),
    fetch('/api/stats', { credentials: 'same-origin' }).then(function(r){ return r.json(); })
  ])
    .then(function(res){
    var d = res[0];
    var teams = (res[1] && res[1].teams) || [];
    var stats = (res[2] && res[2].stats) || { clubs: 0, teams: 0, submissions: 0 };
    var a = d && d.account;
    var partnerSession = (a && a.role === 'partner') ? { orgName: a.orgName, contactName: a.contactName, partnerType: a.partnerType, email: a.email } : null;
  if(!partnerSession){ document.getElementById('no-partner').style.display = 'block'; }
  else {
    document.getElementById('pd-wrap').style.display = 'block';
    document.getElementById('pd-welcome').textContent = 'Bine ai revenit, ' + (partnerSession.orgName || 'partner') + '.';
    document.getElementById('partner-logout-link').addEventListener('click', function(e){
      e.preventDefault();
      fetch('/auth/logout', { method:'POST', credentials:'same-origin' });
      window.location.reload();
    });
    document.getElementById('pd-clubs').textContent = stats.clubs;
    document.getElementById('pd-teams').textContent = stats.teams;
    document.getElementById('pd-subs').textContent = stats.submissions;
    var wrap = document.getElementById('pd-teams-list');
    if(teams.length === 0){ wrap.innerHTML = '<div class="empty-state">Nicio echipă înscrisă încă.</div>'; }
    else {
      wrap.innerHTML = teams.map(function(t){
        // The club's city arrives with the team; the browser no longer
        // matches one array against another on a display name.
        return '<div class="pd-row"><div><strong>' + t.teamName + '</strong><br><span style="font-size:12px;color:var(--ink-soft);">' + (t.clubName||'') + ' &middot; ' + (t.clubCity||'') + ' &middot; ' + t.category + '</span></div><span class="tag" style="background:var(--green);">' + (t.memberCount || 0) + ' membri</span></div>';
      }).join('');
    }
  }
    
    })
    .catch(function(){});
});
}
