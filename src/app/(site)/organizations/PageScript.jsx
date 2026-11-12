"use client";
// The behaviour this page carried as inline <script> blocks, moved here
// unchanged apart from the links (x.html -> /x). It runs once, after
// React has hydrated the markup in page.tsx, and works on that DOM by id.
//
// It is the next thing to rewrite as React state, one page at a time;
// until then it keeps the page doing exactly what it did before.
import { useEffect } from "react";

let started = false;

export default function OrganizationsScript() {
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







  var listEl = document.getElementById('org-list');
  var emptyEl = document.getElementById('empty-state');

  // Both lists were localStorage arrays, so this page showed a visitor
  // the clubs their own browser happened to have stored -- which for
  // anyone arriving for the first time was none at all. They come from
  // the server now, and the two requests go out together because
  // neither depends on the other.
  Promise.all([
    fetch('/api/clubs', { credentials: 'same-origin' }).then(function(r){ return r.json(); }),
    fetch('/api/teams', { credentials: 'same-origin' }).then(function(r){ return r.json(); })
  ])
    .then(function(res){
  var clubs    = (res[0] && res[0].clubs) || [];
  var allTeams = (res[1] && res[1].teams) || [];

  if(clubs.length === 0){
    emptyEl.style.display = 'block';
    return;
  }

  clubs.forEach(function(club){
    var card = document.createElement('div');
    card.className = 'org-card';

    // Matched on the club's id, not its name. The name is a display
    // field a club may change; matching on it meant a rename detached
    // a club from its own teams.
    var clubTeams = allTeams.filter(function(t){ return t.clubId === club.id; });

    var chips = clubTeams.length > 0
      ? clubTeams.map(function(t){
          var cat = t.category || 'Other';
          var teamHref = '/team?id=' + encodeURIComponent(t.id);
          return '<a class="team-chip" href="' + teamHref + '" style="text-decoration:none; color:inherit;"><span class="cat-dot cat-' + cat + '"></span>' + t.teamName.replace(/</g,'&lt;') + '<span class="cat-label">' + cat + '</span></a>';
        }).join('')
      : '<p class="empty-small" style="margin:0;">Nicio echipă adăugată încă.</p>';

    card.innerHTML =
      '<h2>' + club.clubName.replace(/</g,'&lt;') + '</h2>' +
      '<div class="org-meta">' + (club.city || '—').replace(/</g,'&lt;') + ' · ' + clubTeams.length + ' team' + (clubTeams.length !== 1 ? 's' : '') + '</div>' +
      '<div class="team-chip-row">' + chips + '</div>';

    listEl.appendChild(card);
  });
    })
    .catch(function(){
      emptyEl.style.display = 'block';
      var msg = emptyEl.querySelector('p');
      if(msg){ msg.textContent = 'Lista nu a putut fi încărcată. Reîncarcă pagina.'; }
    });
});
}
