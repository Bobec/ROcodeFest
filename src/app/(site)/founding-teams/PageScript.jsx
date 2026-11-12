"use client";
// The behaviour this page carried as inline <script> blocks, moved here
// unchanged apart from the links (x.html -> /x). It runs once, after
// React has hydrated the markup in page.tsx, and works on that DOM by id.
//
// It is the next thing to rewrite as React state, one page at a time;
// until then it keeps the page doing exactly what it did before.
import { useEffect } from "react";

let started = false;

export default function FoundingTeamsScript() {
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







  var grid = document.getElementById('team-grid');
  var wrap = document.getElementById('team-list-wrap');
  var empty = document.getElementById('empty-state');

  // Who is signed in comes from the server. These used to be
  // localStorage keys, which is where three findings came from: a
  // role whose key no navigation bar read, a key nothing cleared,
  // and two keys where one sign-out cleared one. There is one
  // session now and it carries its own role.
  //
  // The teams come from the server too. This page used to read two
  // localStorage arrays and join them in the browser by matching
  // club_name against club_name -- a join on a display name, which a
  // rename silently breaks, and which showed every visitor only the
  // teams that their own browser happened to have stored. The join is
  // in the query now, so /api/teams carries the club's city and number
  // with each team and there is nothing to match up here.
  //
  // Both requests go out together rather than one after the other:
  // they do not depend on each other, and waiting for the first before
  // asking the second would double the time the page shows nothing.
  // The third request answers "which of these have I already asked to
  // join". It 401s or 403s for anyone who is not a signed-in member,
  // and an empty list is the right answer for them, so the failure is
  // absorbed rather than allowed to take the whole page down with it.
  Promise.all([
    fetch('/auth/me',   { credentials: 'same-origin' }).then(function(r){ return r.json(); }),
    fetch('/api/teams', { credentials: 'same-origin' }).then(function(r){ return r.json(); }),
    fetch('/api/join-requests/mine', { credentials: 'same-origin' })
      .then(function(r){ return r.ok ? r.json() : { requests: [] }; })
      .catch(function(){ return { requests: [] }; })
  ])
    .then(function(res){
    var d = res[0];
    var teams = (res[1] && res[1].teams) || [];
    var myRequests = (res[2] && res[2].requests) || [];
    document.getElementById('team-count').textContent = teams.length;
    var a = d && d.account;
    var memberSession = (a && a.role === 'member') ? { memberName: a.fullName, email: a.email, city: a.city } : null;
    var clubSession = (a && a.role === 'club') ? { clubName: a.clubName, number: a.foundingNumber } : null;

  if(teams.length === 0){
    wrap.style.display = 'none';
    empty.style.display = 'block';
  } else {
    empty.style.display = 'none';
    // Give every team a stable, unique display number (registration order),
    // instead of reusing the founding club's number — a club with several
    // teams would otherwise show the same "#" on every one of its teams.
    teams.forEach(function(t, i){ t.displayNumber = i + 1; });
    teams.slice().reverse().forEach(function(t){
      var card = document.createElement('div');
      card.className = 'team-card';

      // myRequests comes from the server with the rest of the page. It
      // used to be a localStorage array matched on team NAME and email,
      // so a member who had asked to join saw an unpressed button on
      // any other computer -- and two teams with the same name in
      // different clubs shared one answer between them. Matched on the
      // team's id now.
      var alreadyRequested = memberSession && myRequests.some(function(r){
        return String(r.teamId) === String(t.id) && r.status === 'pending';
      });
      var alreadyMember = memberSession && myRequests.some(function(r){
        return String(r.teamId) === String(t.id) && r.status === 'accepted';
      });

      // Clubs don't "request to join" teams as a member — show nothing for
      // their own team's card, or a Manage link if it's their own team.
      var actionHtml;
      if(clubSession && clubSession.clubName === t.clubName){
        actionHtml = '<a class="btn btn-secondary btn-small" style="margin-top:12px; width:100%; text-align:center; box-sizing:border-box;" href="/team?id=' + encodeURIComponent(t.id) + '">Administrează echipa →</a>';
      } else if(clubSession){
        actionHtml = '';
      } else {
        var done  = alreadyRequested || alreadyMember;
        var label = alreadyMember ? 'Membru ✓' : (alreadyRequested ? 'Cerere trimisă ✓' : 'Cere să te alături');
        actionHtml = '<button class="join-btn" style="margin-top:12px; width:100%; font-family:\'VT323\',sans-serif; font-weight:700; font-size:13px; padding:9px 0; border-radius:0; border:2px solid var(--line); background:' + (done ? '#2A2A2A' : 'transparent') + '; cursor:' + (done ? 'default' : 'pointer') + ';" ' + (done ? 'disabled' : '') + '>' + label + '</button>';
      }

      var teamHref = '/team?id=' + encodeURIComponent(t.id);
      card.innerHTML = '<span class="badge-num">#' + t.displayNumber + '</span>' +
        '<h3><a href="' + teamHref + '" style="text-decoration:none;">' + t.teamName.replace(/</g,'&lt;') + '</a></h3>' +
        '<p>' + t.clubName.replace(/</g,'&lt;') + ' · ' + (t.clubCity || '—').replace(/</g,'&lt;') + ' · ' + t.category + '</p>' +
        actionHtml;

      var joinBtn = card.querySelector('.join-btn');
      if(joinBtn){
        joinBtn.addEventListener('click', function(){
          if(!memberSession){
            window.location.href = '/join';
            return;
          }
          // The request goes to the club now. It used to be pushed into
          // the MEMBER's own localStorage, while the club's page read
          // the CLUB's -- so both halves of this feature worked and no
          // club ever saw a request from anyone.
          //
          // Who is asking is not in the body: the server takes it from
          // the session. Sending it would let the page ask on someone
          // else's behalf.
          joinBtn.disabled = true;
          fetch('/api/join-requests', {
            method: 'POST',
            credentials: 'same-origin',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ teamId: t.id })
          })
            .then(function(r){ return r.json().then(function(dd){ return { ok: r.ok, d: dd }; }); })
            .then(function(rr){
              if(!rr.ok){
                // A duplicate is not a failure worth alarming anyone
                // about -- it means the request is already in.
                joinBtn.textContent = 'Cerere trimisă ✓';
                joinBtn.title = rr.d.error || '';
                joinBtn.style.background = '#2A2A2A';
                joinBtn.style.cursor = 'default';
                return;
              }
              joinBtn.textContent = 'Cerere trimisă ✓';
              joinBtn.style.background = '#2A2A2A';
              joinBtn.style.cursor = 'default';
            })
            .catch(function(){
              joinBtn.disabled = false;
              joinBtn.textContent = 'Încearcă din nou';
            });
        });
      }

      grid.appendChild(card);
    });
  }
    })
    .catch(function(){
      // A swallowed failure here is indistinguishable from a festival
      // with no teams yet, and the two need different reactions from
      // whoever is looking at the page.
      wrap.style.display = 'none';
      empty.style.display = 'block';
      var msg = empty.querySelector('p');
      if(msg){ msg.textContent = 'Lista de echipe nu a putut fi încărcată. Reîncarcă pagina.'; }
    });
});
}
