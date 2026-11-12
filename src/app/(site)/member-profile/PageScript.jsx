"use client";
// The behaviour this page carried as inline <script> blocks, moved here
// unchanged apart from the links (x.html -> /x). It runs once, after
// React has hydrated the markup in page.tsx, and works on that DOM by id.
//
// It is the next thing to rewrite as React state, one page at a time;
// until then it keeps the page doing exactly what it did before.
import { useEffect } from "react";

let started = false;

export default function MemberProfileScript() {
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
  // The team list comes with it. It used to be two localStorage arrays
  // joined in the browser on club_name, so this page suggested teams
  // only from whatever the visitor's own browser had stored -- for
  // anyone arriving for the first time, nothing at all.
  Promise.all([
    fetch('/auth/me',   { credentials: 'same-origin' }).then(function(r){ return r.json(); }),
    fetch('/api/teams', { credentials: 'same-origin' }).then(function(r){ return r.json(); })
  ])
    .then(function(res){
    var d = res[0];
    var allTeams = (res[1] && res[1].teams) || [];
    var a = d && d.account;
    var memberSession = (a && a.role === 'member') ? { memberName: a.fullName, email: a.email, city: a.city } : null;

  var regLink = document.getElementById('nav-register-link');
  if(memberSession && regLink){
    var mInitial = (memberSession.memberName || '?').trim().charAt(0).toUpperCase();
    regLink.textContent = mInitial;
    regLink.classList.add('profile-avatar', 'member-avatar');
    regLink.title = memberSession.memberName + ' — click ca să-ți vezi profilul';
    regLink.href = '/member-profile';
  }

  if(!memberSession){
    document.getElementById('not-logged-in').style.display = 'block';
    return;
  }

  document.getElementById('profile-content').style.display = 'block';
  var bigAvatar = document.getElementById('p-avatar');
  bigAvatar.textContent = (memberSession.memberName || '?').charAt(0).toUpperCase();
  // Members have a picture now too, and it arrives with the account.
  if(a.avatar){ bigAvatar.style.backgroundImage = 'url(' + a.avatar + ')'; bigAvatar.textContent = ''; }
  document.getElementById('p-name').textContent = memberSession.memberName;
  document.getElementById('p-city-email').textContent = memberSession.city + ' · ' + memberSession.email;
  document.getElementById('p-city').textContent = memberSession.city || '—';
  document.getElementById('p-email').textContent = memberSession.email || '—';
  document.getElementById('p-message').textContent = memberSession.message || 'Nimic adăugat încă.';

  // The join that used to happen here is in the query now: /api/teams
  // carries each team's club city with it. This only renames the field
  // so the rest of the page reads as it did.
  function getTeams(){
    return allTeams.map(function(t){
      return { id: t.id, teamName: t.teamName, category: t.category,
               clubName: t.clubName, city: t.clubCity || '' };
    });
  }
  // My own requests, from the server. They used to be filtered out of a
  // shared localStorage array by matching on email, which is why a
  // member saw an empty list on any computer but the one they had asked
  // from -- and why the club, reading its own browser, saw nothing at
  // all.
  //
  // Kept in a variable and re-fetched after a change, so the two
  // renders below always draw the same answer.
  var myRequests = [];

  function loadRequests(){
    return fetch('/api/join-requests/mine', { credentials: 'same-origin' })
      .then(function(r){ return r.ok ? r.json() : { requests: [] }; })
      .then(function(d){ myRequests = (d && d.requests) || []; })
      .catch(function(){ myRequests = []; });
  }

  function myRequestedTeamIds(){
    return myRequests.map(function(r){ return String(r.teamId); });
  }

  function renderSuggestions(){
    var teams = getTeams();
    var grid = document.getElementById('suggest-grid');
    var emptyMsg = document.getElementById('no-suggestions');
    grid.innerHTML = '';

    if(teams.length === 0){
      emptyMsg.style.display = 'block';
      return;
    }
    emptyMsg.style.display = 'none';

    // Matched on the team's id. Matching on the name meant two teams
    // called the same thing in different clubs counted as one.
    var already = myRequestedTeamIds();
    var candidates = teams.filter(function(t){ return already.indexOf(String(t.id)) === -1; });

    // Prioritize same-city matches, then everything else, cap at 4
    var sameCity = candidates.filter(function(t){ return t.city && t.city.toLowerCase() === memberSession.city.toLowerCase(); });
    var others = candidates.filter(function(t){ return sameCity.indexOf(t) === -1; });
    var suggestions = sameCity.concat(others).slice(0, 4);

    if(suggestions.length === 0){
      grid.innerHTML = '<p class="empty-small">Ai cerut deja să te alături tuturor echipelor înscrise — frumoasă inițiativă!</p>';
      return;
    }

    suggestions.forEach(function(t){
      var isMatch = t.city && t.city.toLowerCase() === memberSession.city.toLowerCase();
      var card = document.createElement('div');
      card.className = 'suggest-card';
      card.innerHTML =
        (isMatch ? '<span class="match-tag">Același oraș</span>' : '') +
        '<h3></h3><p></p>' +
        '<button class="join-btn">Cere să te alături</button>';
      card.querySelector('h3').textContent = t.teamName;
      card.querySelector('p').textContent = t.clubName + ' · ' + t.city + ' · ' + t.category;

      var btn = card.querySelector('.join-btn');
      btn.addEventListener('click', function(){
        btn.disabled = true;
        // Only the team is sent. Who is asking comes from the session,
        // so this cannot be used to request on someone else's behalf.
        fetch('/api/join-requests', {
          method: 'POST',
          credentials: 'same-origin',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ teamId: t.id })
        })
          .then(function(r){ return r.json().then(function(dd){ return { ok: r.ok, d: dd }; }); })
          .then(function(rr){
            if(!rr.ok){ btn.textContent = rr.d.error || 'Cererea nu a reușit'; return; }
            // Re-read rather than assume: the answer the server holds
            // is the one both lists below have to agree with.
            return loadRequests().then(function(){
              renderSuggestions();
              renderMyRequests();
            });
          })
          .catch(function(){ btn.disabled = false; btn.textContent = 'Încearcă din nou'; });
      });

      grid.appendChild(card);
    });
  }

  function renderMyRequests(){
    // Already scoped to me: the endpoint filters by the session's own
    // account, so there is nothing to filter here.
    var mine = myRequests;
    var wrap = document.getElementById('my-requests-list');
    var emptyMsg = document.getElementById('no-my-requests');
    wrap.innerHTML = '';

    if(mine.length === 0){
      emptyMsg.style.display = 'block';
      return;
    }
    emptyMsg.style.display = 'none';

    // Already newest-first from the query; no reverse needed.
    mine.forEach(function(r){
      var status = r.status || 'pending';
      var row = document.createElement('div');
      row.className = 'req-item';
      var viewLink = '';
      if(status === 'accepted'){
        // The club name arrives with the request. Looking it up in the
        // team list by name is what findTeamClub used to do, and it
        // could not tell two teams with the same name apart.
        viewLink = '<a class="empty-small" style="text-decoration:underline; margin-left:10px;" href="/team?id=' + encodeURIComponent(r.teamId) + '">Vezi echipa →</a>';
      }
      row.innerHTML =
        '<div class="rq-name"></div>' +
        '<span><span class="status-tag status-' + status + '"></span>' + viewLink + '</span>';
      row.querySelector('.rq-name').textContent = r.teamName;
      row.querySelector('.status-tag').textContent = status.charAt(0).toUpperCase() + status.slice(1);
      wrap.appendChild(row);
    });
  }

  loadRequests().then(function(){
    renderSuggestions();
    renderMyRequests();
  });

  document.getElementById('logout-link').addEventListener('click', function(){
    fetch('/auth/logout', { method:'POST', credentials:'same-origin' });
    window.location.href = '/';
  });
    })
    .catch(function(){});
});
}
