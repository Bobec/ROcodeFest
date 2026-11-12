"use client";
// The behaviour this page carried as inline <script> blocks, moved here
// unchanged apart from the links (x.html -> /x). It runs once, after
// React has hydrated the markup in page.tsx, and works on that DOM by id.
//
// It is the next thing to rewrite as React state, one page at a time;
// until then it keeps the page doing exactly what it did before.
import { useEffect } from "react";

let started = false;

export default function JudgeScoringScript() {
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






  
  // Who the judge is comes from the server now. It used to be
  // rocodefest_judge_session in localStorage -- a key no navigation bar
  // read and nothing anywhere cleared, so a signed-in judge was shown as
  // signed out and could not sign out at all.
  //
  // The page waits for the answer instead of reading it synchronously.
  // That is the one structural change asking a server rather than a
  // browser forces on a page like this.
  // The matches this judge is officiating, and the scores they have
  // already given. Both used to be a localStorage array, so a judge
  // changing computers arrived with an empty history and nobody could
  // ever see anyone else's scores -- which is why the leaderboard had
  // nothing to read.
  Promise.all([
    fetch('/auth/me', { credentials: 'same-origin' }).then(function(r){ return r.json(); }),
    fetch('/api/scores/matches', { credentials: 'same-origin' })
      .then(function(r){ return r.ok ? r.json() : { matches: [] }; })
      .catch(function(){ return { matches: [] }; })
  ])
    .then(function(res){
  var d = res[0];
  var matches = (res[1] && res[1].matches) || [];
  var a = d && d.account;
  var judgeSession = (a && a.role === 'judge') ? { name: a.fullName, email: a.email } : null;
  if(!judgeSession){ document.getElementById('no-judge').style.display = 'block'; }
  else {
    document.getElementById('scoring-wrap').style.display = 'block';
    var matchSel = document.getElementById('score-match');
    var sel = document.getElementById('score-team');

    if(matches.length === 0){
      var none = document.createElement('option');
      none.value = '';
      none.textContent = 'Nu ești în comisia niciunui meci';
      matchSel.appendChild(none);
    }
    matches.forEach(function(m){
      var o = document.createElement('option');
      o.value = m.id;
      o.textContent = (m.roundName || 'Meci #' + m.id) + ' · ' + m.challengeName + ' · ' + m.status;
      matchSel.appendChild(o);
    });

    // The teams offered are the ones that were IN the chosen match.
    // fk_scores_match_team refuses any other pairing anyway; filling
    // the dropdown from the match means the refusal never has to
    // happen.
    matchSel.addEventListener('change', function(){
      sel.innerHTML = '';
      var m = matches.filter(function(x){ return String(x.id) === String(matchSel.value); })[0];
      if(!m){ sel.innerHTML = '<option value="">Alege mai întâi un meci…</option>'; return; }
      var head = document.createElement('option');
      head.value = ''; head.textContent = 'Alege o echipă...';
      sel.appendChild(head);
      m.teams.forEach(function(t){
        var o = document.createElement('option');
        o.value = t.id;
        // Already scored is shown rather than hidden: one score per
        // judge per team per match is a unique constraint, and a judge
        // needs to know why an option is unavailable.
        o.textContent = t.teamName + ' (' + t.clubName + ')' + (t.scored ? ' — deja punctată' : '');
        o.disabled = !!t.scored;
        sel.appendChild(o);
      });
    });

    var myScores = [];
    function loadScores(){
      return fetch('/api/scores/mine', { credentials: 'same-origin' })
        .then(function(r){ return r.ok ? r.json() : { scores: [] }; })
        .then(function(dd){ myScores = (dd && dd.scores) || []; })
        .catch(function(){ myScores = []; });
    }

    function renderMyScores(){
      var wrap = document.getElementById('my-scores-list');
      if(myScores.length === 0){ wrap.innerHTML = '<div class="empty-state">Niciun punctaj trimis încă.</div>'; return; }
      wrap.innerHTML = '<div class="card">' + myScores.map(function(s){
        return '<div class="score-card"><div><strong>' + s.teamName.replace(/</g,'&lt;') + '</strong><br><span style="font-size:12px;color:var(--ink-soft);">' + (s.roundName || '') + (s.comment ? ' · ' + s.comment.replace(/</g,'&lt;') : '') + '</span></div><div class="score-total">' + s.total + '/40</div></div>';
      }).join('') + '</div>';
    }

    loadScores().then(renderMyScores);

    var submitBtn = document.getElementById('submit-score-btn');
    submitBtn.addEventListener('click', function(){
      var errEl = document.getElementById('score-error');
      if(!matchSel.value || !sel.value){
        errEl.textContent = 'Alege meciul și echipa.';
        errEl.classList.add('show');
        return;
      }
      errEl.classList.remove('show');

      submitBtn.disabled = true;
      // total is GENERATED ALWAYS in the database, so it is not sent --
      // this page used to compute it. Sending it would raise 428C9.
      fetch('/api/scores', {
        method: 'POST',
        credentials: 'same-origin',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          matchId: matchSel.value,
          teamId: sel.value,
          innovation:   parseInt(document.getElementById('s-innovation').value, 10),
          execution:    parseInt(document.getElementById('s-execution').value, 10),
          presentation: parseInt(document.getElementById('s-presentation').value, 10),
          teamwork:     parseInt(document.getElementById('s-teamwork').value, 10),
          comment: document.getElementById('s-comment').value.trim()
        })
      })
        .then(function(r){ return r.json().then(function(dd){ return { ok: r.ok, d: dd }; }); })
        .then(function(rr){
          submitBtn.disabled = false;
          if(!rr.ok){
            // Each refusal names a different thing: not on the panel,
            // team not in the match, already scored, match not playable.
            errEl.textContent = rr.d.error || 'Punctajul nu a putut fi trimis.';
            errEl.classList.add('show');
            return;
          }
          document.getElementById('s-comment').value = '';
          ['s-innovation','s-execution','s-presentation','s-teamwork'].forEach(function(id){ document.getElementById(id).value = 5; });
          ['v-inn','v-exe','v-pre','v-tea'].forEach(function(id){ document.getElementById(id).textContent = '5'; });
          // Re-read: the team just scored has to become unavailable.
          return fetch('/api/scores/matches', { credentials: 'same-origin' })
            .then(function(r){ return r.ok ? r.json() : { matches: [] }; })
            .then(function(dd){
              matches = (dd && dd.matches) || [];
              matchSel.dispatchEvent(new Event('change'));
              return loadScores().then(renderMyScores);
            });
        })
        .catch(function(){ submitBtn.disabled = false; errEl.textContent = 'Serverul nu răspunde.'; errEl.classList.add('show'); });
    });
  }
    })
    .catch(function(){
      // With the API unreachable the page shows its signed-out state,
      // which is the honest answer: it cannot know who is here.
      document.getElementById('no-judge').style.display = 'block';
    });
    
});

// was an inline oninput="..." attribute in the HTML page
document.getElementById("s-innovation").addEventListener("input", function(){ document.getElementById('v-inn').textContent=this.value });

// was an inline oninput="..." attribute in the HTML page
document.getElementById("s-execution").addEventListener("input", function(){ document.getElementById('v-exe').textContent=this.value });

// was an inline oninput="..." attribute in the HTML page
document.getElementById("s-presentation").addEventListener("input", function(){ document.getElementById('v-pre').textContent=this.value });

// was an inline oninput="..." attribute in the HTML page
document.getElementById("s-teamwork").addEventListener("input", function(){ document.getElementById('v-tea').textContent=this.value });
}
