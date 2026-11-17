"use client";
// The behaviour this page carried as inline <script> blocks, moved here
// unchanged apart from the links (x.html -> /x). It runs once, after
// React has hydrated the markup in page.tsx, and works on that DOM by id.
//
// It is the next thing to rewrite as React state, one page at a time;
// until then it keeps the page doing exactly what it did before.
import { useEffect } from "react";

let started = false;

export default function LeaderboardScript() {
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







  // The leaderboard comes from the server, computed live from the
  // scores judges have entered. It used to be six teams written into
  // this page with a note promising real rankings "once the backend is
  // connected".
  //
  // Only completed matches count, and a team's score for a match is the
  // average across its panel -- so the table changes the moment an
  // organiser marks a match finished, with nothing to schedule and no
  // cache to clear.
  var lbTeams = [];
  var lbSeason = null;

  function renderCategoryTabs(){
    var tabRow = document.getElementById('cat-tabs');
    tabRow.innerHTML = '';
    // Drawn from the categories actually present in the standings. A
    // fixed list would offer tabs that are empty all season.
    var categories = ['Toate'];
    lbTeams.forEach(function(t){
      if(categories.indexOf(t.categoryLabel) === -1) categories.push(t.categoryLabel);
    });
    categories.forEach(function(c){
      var btn = document.createElement('button');
      btn.className = 'tab-btn' + (c === 'Toate' ? ' active' : '');
      btn.textContent = c;
      btn.addEventListener('click', function(){
        tabRow.querySelectorAll('.tab-btn').forEach(function(b){ b.classList.remove('active'); });
        btn.classList.add('active');
        renderLB(c);
      });
      tabRow.appendChild(btn);
    });
  }

  function renderLB(cat){
    var wrap = document.getElementById('lb-list');
    var ranked = lbTeams.filter(function(t){ return cat === 'Toate' || t.categoryLabel === cat; });

    if(ranked.length === 0){
      wrap.innerHTML = '<div class="empty-state">' +
        (lbSeason
          ? 'Niciun punctaj încă pentru ' + cat + '. Clasamentul apare pe măsură ce meciurile se încheie.'
          : 'Niciun sezon activ momentan.') +
        '</div>';
      return;
    }

    // The rank comes from the server, where ties share a place: two
    // teams on 87 are both 3rd and the next is 5th. Using the array
    // index here would silently make one of them 4th.
    var best = ranked[0].totalScore || 1;
    wrap.innerHTML = ranked.map(function(t){
      var cls = t.rank === 1 ? 'gold' : t.rank === 2 ? 'silver' : t.rank === 3 ? 'bronze' : '';
      // The bar is relative to the leader rather than to a fixed 40:
      // a team plays several matches, so the total has no ceiling.
      var pct = Math.max(4, (t.totalScore / best) * 100);
      var meta = [t.clubName, t.clubCity, t.categoryLabel]
        .filter(Boolean).map(function(s){ return String(s).replace(/</g,'&lt;'); }).join(' &middot; ');
      return '<div class="lb-row">' +
        '<div class="lb-rank ' + cls + '">' + t.rank + '</div>' +
        '<div class="lb-name"><strong>' + String(t.teamName).replace(/</g,'&lt;') + '</strong>' +
          '<p>' + meta + ' &middot; ' + t.matchesPlayed + ' meci(uri)</p>' +
          '<div class="lb-bar" style="width:' + pct + '%;"></div></div>' +
        '<div class="lb-score">' + t.totalScore + '</div>' +
      '</div>';
    }).join('');
  }

  fetch('/api/leaderboard', { credentials: 'same-origin' })
    .then(function(r){ return r.json(); })
    .then(function(d){
      lbTeams = (d && d.teams) || [];
      lbSeason = d && d.seasonName;
      var head = document.getElementById('lb-season-line');
      if(head){
        head.textContent = lbSeason
          ? 'Clasament ' + lbSeason + ' — se actualizează pe măsură ce meciurile se încheie.'
          : 'Niciun sezon activ momentan.';
      }
      renderCategoryTabs();
      renderLB('Toate');
    })
    .catch(function(){
      document.getElementById('lb-list').innerHTML =
        '<div class="empty-state">Clasamentul nu a putut fi încărcat. Reîncarcă pagina.</div>';
    });

});
}
