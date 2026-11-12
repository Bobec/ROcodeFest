"use client";
// The behaviour this page carried as inline <script> blocks, moved here
// unchanged apart from the links (x.html -> /x). It runs once, after
// React has hydrated the markup in page.tsx, and works on that DOM by id.
//
// It is the next thing to rewrite as React state, one page at a time;
// until then it keeps the page doing exactly what it did before.
import { useEffect } from "react";

let started = false;

export default function AppealsScript() {
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






  // The twelve rule codes that stood here were written into the page,
  // and the rules table has no rows behind any of them -- so every code
  // in the dropdown named a rule that does not exist, and citing one
  // could never have produced an appeal.
  //
  // They come from the table now. While it is empty the picker offers
  // only "not sure / other", which is the truthful state: the
  // regulations have not been loaded yet, and an appeal without a
  // citation is still a valid appeal -- rule_id is nullable.
  var ruleSelect = document.getElementById('ap-rule-code');
  fetch('/api/appeals/rules', { credentials: 'same-origin' })
    .then(function(r){ return r.ok ? r.json() : { rules: [] }; })
    .then(function(d){
      (d.rules || []).forEach(function(r){
        var o = document.createElement('option');
        o.value = r.id;
        o.textContent = r.code + ' — ' + r.title;
        ruleSelect.appendChild(o);
      });
    })
    .catch(function(){});
 // TODO: placeholder — intentionally not navigating anywhere yet. Once the
  // backend serves real regulations content, this will deep-link to the
  // selected rule. Flashes the hint text so the button still gives visible
  // feedback instead of appearing unresponsive.
  var ruleHintTimer = null;
  document.getElementById('ap-ref-rules-btn').addEventListener('click', function(){
    var hint = document.querySelector('.rule-hint');
    if(!hint) return;
    if(!hint.getAttribute('data-original')){ hint.setAttribute('data-original', hint.textContent); }
    hint.textContent = '📖 Doar machetă deocamdată — va deschide regulamentul oficial după conectarea la server.';
    hint.style.color = 'var(--coral-dark)';
    hint.style.fontWeight = '700';
    clearTimeout(ruleHintTimer);
    ruleHintTimer = setTimeout(function(){
      hint.textContent = hint.getAttribute('data-original');
      hint.style.color = '';
      hint.style.fontWeight = '';
    }, 2400);
  });

  function pad2(n){ n = parseInt(n,10) || 0; return (n < 10 ? '0' : '') + n; }
  function readTimestamp(){
    var h = parseInt(document.getElementById('ap-ts-h').value, 10) || 0;
    var m = document.getElementById('ap-ts-m').value;
    var s = document.getElementById('ap-ts-s').value;
    if(!m && !s && !h) return '';
    return h + ':' + pad2(m) + ':' + pad2(s);
  }
  function clearTimestamp(){
    document.getElementById('ap-ts-h').value = '';
    document.getElementById('ap-ts-m').value = '';
    document.getElementById('ap-ts-s').value = '';
  }

  // Who is signed in comes from the server. These used to be
  // localStorage keys, which is where three findings came from: a
  // role whose key no navigation bar read, a key nothing cleared,
  // and two keys where one sign-out cleared one. There is one
  // session now and it carries its own role.
  // /api/teams/mine, not the whole list filtered in the browser: the
  // endpoint scopes to the session's club, so which teams a club may
  // appeal for is decided on the server rather than by a comparison a
  // page could be edited to skip.
  Promise.all([
    fetch('/auth/me',        { credentials: 'same-origin' }).then(function(r){ return r.json(); }),
    fetch('/api/teams/mine', { credentials: 'same-origin' })
      .then(function(r){ return r.ok ? r.json() : { teams: [] }; })
  ])
    .then(function(res){
    var d = res[0];
    var mine = (res[1] && res[1].teams) || [];
    var a = d && d.account;
    var clubSession = (a && a.role === 'club') ? { clubName: a.clubName, number: a.foundingNumber } : null;
  if(!clubSession){ document.getElementById('no-club-a').style.display = 'block'; }
  else {
    document.getElementById('appeal-wrap').style.display = 'block';
    var sel = document.getElementById('ap-team');
    // The id, not the name -- the server has no way to tell two teams
    // with the same name apart, nor should it have to.
    mine.forEach(function(t){ var o = document.createElement('option'); o.value = t.id; o.textContent = t.teamName; sel.appendChild(o); });

    var appeals = [];
    function loadAppeals(){
      return fetch('/api/appeals', { credentials: 'same-origin' })
        .then(function(r){ return r.ok ? r.json() : { appeals: [] }; })
        .then(function(d){ appeals = (d && d.appeals) || []; })
        .catch(function(){ appeals = []; });
    }

    function renderAppeals(){
      var wrap = document.getElementById('ap-list');
      // Already scoped to my club and newest-first by the query.
      if(appeals.length === 0){ wrap.innerHTML = '<div class="empty-state">Nicio contestație depusă.</div>'; return; }
      wrap.innerHTML = '<div class="card">' + appeals.map(function(a){
        var st = a.status || 'pending';
        var cls = st === 'accepted' ? 'ap-accepted' : st === 'rejected' ? 'ap-rejected' : 'ap-pending';
        // The rule now comes from the rules table, with its real title.
        var ruleTag = a.ruleCode ? '<span class="ap-rule-tag" title="' + (a.ruleTitle||'').replace(/"/g,'&quot;') + '">' + a.ruleCode + '</span>' : '';
        return '<div class="ap-item"><strong>' + a.teamName.replace(/</g,'&lt;') + '</strong> <span class="ap-status ' + cls + '">' + st + '</span>' + ruleTag + '<br><span style="font-size:12px;color:var(--ink-soft);">Moment: ' + (a.timestamp || 'N/A') + '</span><p style="font-size:13px;margin:6px 0 0;">' + a.reason.replace(/</g,'&lt;') + '</p></div>';
      }).join('') + '</div>';
    }

    loadAppeals().then(renderAppeals);

    var apBtn = document.getElementById('ap-btn');
    apBtn.addEventListener('click', function(){
      var teamId = sel.value; var reason = document.getElementById('ap-reason').value.trim();
      var errEl = document.getElementById('ap-error');
      if(!teamId || !reason){ errEl.textContent = 'Alege o echipă și explică motivul contestației.'; errEl.classList.add('show'); return; }
      errEl.classList.remove('show');

      // The "three rejected appeals and you may file no more" check that
      // stood here counted entries in this browser's own array, so it
      // reset with site data and applied to nobody else.
      //
      // The rule itself is real -- enforce_appeal_limit, in the schema,
      // per team. This page was keeping a second copy of it. The copy is
      // gone; the refusal comes back from the server with the team and
      // the limit named in it.
      apBtn.disabled = true;
      fetch('/api/appeals', {
        method: 'POST',
        credentials: 'same-origin',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          teamId: teamId,
          reason: reason,
          ruleId: ruleSelect.value || null,
          timestamp: readTimestamp()
        })
      })
        .then(function(r){ return r.json().then(function(dd){ return { ok: r.ok, d: dd }; }); })
        .then(function(rr){
          apBtn.disabled = false;
          if(!rr.ok){ errEl.textContent = rr.d.error || 'Contestația nu a putut fi trimisă.'; errEl.classList.add('show'); return; }
          document.getElementById('ap-reason').value = ''; clearTimestamp();
          document.getElementById('ap-target').value = ''; ruleSelect.value = ''; sel.value = '';
          return loadAppeals().then(renderAppeals);
        })
        .catch(function(){ apBtn.disabled = false; errEl.textContent = 'Serverul nu răspunde.'; errEl.classList.add('show'); });
    });
  }

    })
    .catch(function(){});
});
}
