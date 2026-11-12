"use client";
// The behaviour this page carried as inline <script> blocks, moved here
// unchanged apart from the links (x.html -> /x). It runs once, after
// React has hydrated the markup in page.tsx, and works on that DOM by id.
//
// It is the next thing to rewrite as React state, one page at a time;
// until then it keeps the page doing exactly what it did before.
import { useEffect } from "react";

let started = false;

export default function ProfileScript() {
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




  // Who is signed in comes from the server. This page read two
  // localStorage keys and picked between them, which is where three
  // findings came from: a role whose key no navigation bar read, a key
  // nothing anywhere cleared, and two keys where one sign-out cleared
  // one. There is one session now and it carries its own role.
  //
  // The whole page moves inside the callback: asking a server makes the
  // answer asynchronous, and everything below needs it.
  var regLink = document.getElementById('nav-register-link');
  fetch('/auth/me', { credentials: 'same-origin' })
    .then(function(r){ return r.json(); })
    .then(function(d){
  var a = d && d.account;
  var session = (a && a.role === 'club') ? { clubName: a.clubName, number: a.foundingNumber } : null;

  // Anyone signed in, whatever their role -- not just a club.
  var loginLink = document.getElementById('nav-login-link');
  if(a && loginLink){ loginLink.style.display = 'none'; }

  if(session && regLink){
    var initial = (session.clubName || '?').trim().charAt(0).toUpperCase();
    regLink.textContent = initial;
    regLink.classList.add('profile-avatar');
    regLink.title = session.clubName + ' — click ca să-ți vezi clubul';
    regLink.href = '/profile';
  } else if(a && regLink){
    // any other role still gets an avatar, which the two-key version
    // could not give a judge or a partner at all
    var other = a.fullName || a.orgName || a.contactName || '?';
    regLink.textContent = other.trim().charAt(0).toUpperCase();
    regLink.classList.add('profile-avatar', 'member-avatar');
    regLink.title = other;
    regLink.href = a.role === 'member'  ? '/member-profile'
                 : a.role === 'judge'   ? '/judge-scoring'
                 : '/partner-dashboard';
  }

  if(!session){
    document.getElementById('not-logged-in').style.display = 'block';
    return;
  }

  document.getElementById('profile-content').style.display = 'block';

  // The club record used to be looked up in a localStorage array, by name.
  // /auth/me already returns every field this page shows, so that lookup
  // was reading a stale copy of data we were holding in hand -- and it
  // matched on club_name, which is exactly what renaming a club breaks.
  var club = a;

  // The avatar is a column now, not rocodefest_avatar_<name>. It arrives
  // with the account, so the picture no longer disappears on a different
  // computer and nothing has to guess a key from a display name.
  var avatar = a.avatar || null;

  function applyAvatar(){
    var bigAvatar = document.getElementById('p-avatar');
    if(avatar){
      bigAvatar.style.backgroundImage = 'url(' + avatar + ')';
      bigAvatar.textContent = '';
      if(regLink){
        regLink.style.backgroundImage = 'url(' + avatar + ')';
        regLink.textContent = '';
      }
    } else {
      bigAvatar.style.backgroundImage = '';
      bigAvatar.textContent = (club.clubName || '?').charAt(0).toUpperCase();
      if(regLink){
        regLink.style.backgroundImage = '';
        regLink.textContent = (session.clubName || '?').trim().charAt(0).toUpperCase();
      }
    }
  }

  document.getElementById('p-avatar').textContent = (club.clubName || '?').charAt(0).toUpperCase();
  document.getElementById('p-team-name').textContent = club.clubName || session.clubName;
  document.getElementById('p-org-city').textContent = club.city || '—';
  document.getElementById('p-coach').textContent = club.coachName || '—';
  document.getElementById('p-email').textContent = a.email || '—';
  document.getElementById('p-number').textContent = '#' + (club.foundingNumber || '—');

  // Teams
  //
  // /api/teams/mine is scoped to the session's club, so there is no
  // "which of these are mine" filter here any more -- that comparison
  // was on club NAME, and a club renaming itself lost every team it had.
  var teams = [];

  function loadTeams(){
    return fetch('/api/teams/mine', { credentials: 'same-origin' })
      .then(function(r){ return r.ok ? r.json() : { teams: [] }; })
      .then(function(d){ teams = (d && d.teams) || []; })
      .catch(function(){ teams = []; });
  }

  // The category list is read from the server too, so adding a category
  // is a change to a table rather than to four pages.
  var categories = [];
  function loadCategories(){
    return fetch('/api/teams/categories', { credentials: 'same-origin' })
      .then(function(r){ return r.json(); })
      .then(function(d){ categories = (d && d.categories) || []; })
      .catch(function(){ categories = []; });
  }

  var catColors = { ROBOTICS:'var(--blue)', PROGRAMMING:'var(--green)', DESIGN:'var(--purple)', OTHER:'var(--yellow)' };

  function renderTeams(){
    var wrap = document.getElementById('teams-list');
    wrap.innerHTML = '';
    document.getElementById('p-team-count').textContent = teams.length;

    if(teams.length === 0){
      wrap.innerHTML = '<p class="empty-small">Nicio echipă încă — adaugă prima mai jos.</p>';
      return;
    }

    teams.forEach(function(t){
      var card = document.createElement('div');
      card.className = 'team-card-full';

      // The four-stage track that stood here read
      // rocodefest_progress_<club>_<team>, a counter this browser wrote
      // and this browser read. Nothing else in the site could see it,
      // which is why the partner dashboard showed every team as
      // "Registered" forever. It is gone rather than reconnected: there
      // is no definition yet of what makes a team reach a stage.
      //
      // What is shown instead is true and checkable: who is on the
      // team, how full it is, and the code it competes under.
      card.innerHTML =
        '<div class="team-card-head">' +
          '<div><h3></h3><span class="team-cat-badge" style="background:' + (catColors[t.category] || 'var(--ink-soft)') + '"></span></div>' +
          '<button class="remove-btn">Elimină</button>' +
        '</div>' +
        '<div class="team-participants"><strong>Membri:</strong> <span class="p-list"></span></div>' +
        '<div class="team-card-actions"><a class="btn btn-secondary btn-small" href="/team?id=' + encodeURIComponent(t.id) + '">Administrează echipa →</a></div>';

      card.querySelector('h3').textContent = t.teamName;
      card.querySelector('.team-cat-badge').textContent = t.categoryLabel || t.category;

      var onThisTeam = clubMembers.filter(function(m){ return String(m.teamId) === String(t.id); });
      card.querySelector('.p-list').textContent =
        (onThisTeam.length > 0 ? onThisTeam.map(function(m){ return m.memberName; }).join(', ') : 'Niciunul încă') +
        ' (' + t.memberCount + '/' + t.maxMembers + ') · cod ' + t.participationCode;

      card.querySelector('.remove-btn').addEventListener('click', function(){
        // Not implemented on the server yet. Removing a team is not a
        // delete -- teams carry scores, submissions and memberships --
        // so it needs is_active and a decision about what happens to
        // them. Saying so beats a button that quietly does nothing.
        alert('Retragerea unei echipe nu este încă disponibilă. Scrie-ne și o facem manual.');
      });

      wrap.appendChild(card);
    });
  }

  var selectedCategoryId = null;

  // Drawn from the table, so a chip always names a category that exists
  // and always carries its real id. The colours and glyphs stay here:
  // they are presentation, and the table has no opinion about them.
  var CAT_STYLE = {
    ROBOTICS:    { color: 'var(--blue)',   glyph: '🤖' },
    PROGRAMMING: { color: 'var(--green)',  glyph: '💻' },
    DESIGN:      { color: 'var(--purple)', glyph: '🎨' },
    OTHER:       { color: 'var(--yellow)', glyph: '✦' }
  };

  function renderCategoryPicker(){
    var picker = document.getElementById('cat-picker');
    picker.innerHTML = '';
    categories.forEach(function(cat, i){
      var style = CAT_STYLE[cat.code] || { color: 'var(--ink-soft)', glyph: '•' };
      var chip = document.createElement('button');
      chip.type = 'button';
      chip.className = 'cat-chip';
      chip.textContent = style.glyph + ' ' + cat.label;
      chip.addEventListener('click', function(){
        picker.querySelectorAll('.cat-chip').forEach(function(c){
          c.classList.remove('selected');
          c.style.background = 'var(--panel)';
        });
        chip.classList.add('selected');
        chip.style.background = style.color;
        selectedCategoryId = cat.id;
      });
      picker.appendChild(chip);
      // Preselect the first, as the page used to preselect Robotics.
      if(i === 0){ chip.classList.add('selected'); chip.style.background = style.color; selectedCategoryId = cat.id; }
    });
  }

  // The "participants" tag input that stood here collected typed-in
  // names alongside the team. They were not accounts, so nobody typed
  // in could sign in, submit, or appear anywhere else -- and the
  // members who HAD registered and been accepted were not among them.
  // A team is filled by accepting join requests; there is nothing to
  // type here.

  var addTeamBtn = document.getElementById('add-team-btn');
  addTeamBtn.addEventListener('click', function(){
    var nameEl = document.getElementById('new-team-name');
    var codeEl = document.getElementById('new-team-code');
    var errEl  = document.getElementById('add-team-error');
    var name = nameEl.value.trim();
    var code = codeEl.value.trim();

    function fail(msg){ errEl.textContent = msg; errEl.style.display = 'block'; }
    errEl.style.display = 'none';

    if(!name){ return fail('Dă echipei un nume.'); }
    if(!selectedCategoryId){ return fail('Alege o categorie.'); }
    if(!code){ return fail('Codul de participare este obligatoriu.'); }

    addTeamBtn.disabled = true;
    fetch('/api/teams', {
      method: 'POST',
      credentials: 'same-origin',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ teamName: name, categoryId: selectedCategoryId, participationCode: code })
    })
      .then(function(r){ return r.json().then(function(dd){ return { ok: r.ok, d: dd }; }); })
      .then(function(rr){
        addTeamBtn.disabled = false;
        if(!rr.ok){
          // The messages come from the server, which knows which
          // constraint refused: a duplicate code and a duplicate name
          // within the club are different problems with different fixes.
          return fail(rr.d.error || 'Echipa nu a putut fi creată.');
        }
        nameEl.value = '';
        codeEl.value = '';
        return loadTeams().then(renderTeams);
      })
      .catch(function(){ addTeamBtn.disabled = false; fail('Serverul nu răspunde.'); });
  });

  // Members
  //
  // This was rocodefest_members_<clubName>: a list of names typed into a
  // box, in the club's own browser. A name on that list was not an
  // account -- it could not sign in, could not submit anything, and did
  // not appear anywhere else on the site. Meanwhile the member who HAD
  // registered and been accepted was not on it, because nothing ever
  // put them there.
  //
  // The list is the club's real memberships now: people with accounts,
  // on teams, arrived at by accepting a join request.
  var clubMembers = [];

  function loadMembers(){
    return fetch('/api/memberships/club', { credentials: 'same-origin' })
      .then(function(r){ return r.ok ? r.json() : { members: [] }; })
      .then(function(d){ clubMembers = (d && d.members) || []; })
      .catch(function(){ clubMembers = []; });
  }

  function renderMembers(){
    var wrap = document.getElementById('members-list');
    wrap.innerHTML = '';
    if(clubMembers.length === 0){
      wrap.innerHTML = '<p class="empty-small">Niciun membru încă — membrii apar aici după ce le accepți cererea de înscriere.</p>';
      return;
    }
    clubMembers.forEach(function(m){
      var row = document.createElement('div');
      row.className = 'member-row';
      row.innerHTML =
        '<div><div class="m-name"></div><div class="m-role"></div></div>' +
        '<button class="remove-btn">Elimină</button>';
      row.querySelector('.m-name').textContent = m.memberName;
      row.querySelector('.m-role').textContent = m.teamName + (m.roleTitle ? ' · ' + m.roleTitle : '');
      // The id, not a position in an array. Removing by index meant a
      // list that had changed since it was drawn removed the wrong row.
      row.querySelector('.remove-btn').addEventListener('click', function(){
        fetch('/api/memberships/' + m.id, { method: 'DELETE', credentials: 'same-origin' })
          .then(function(){ return loadMembers(); })
          .then(renderMembers)
          .catch(function(){});
      });
      wrap.appendChild(row);
    });
  }

  // Join requests directed at this club's teams
  //
  // This is the half that never met the other one. A member's request
  // was pushed into the MEMBER's localStorage, and this page read the
  // CLUB's -- so both sides worked and no club ever saw a request from
  // anyone. /api/join-requests/incoming is scoped to the session's club
  // by the query, so there is no filtering to do here and no team-name
  // comparison to get wrong.
  var incoming = [];

  function loadRequests(){
    return fetch('/api/join-requests/incoming', { credentials: 'same-origin' })
      .then(function(r){ return r.ok ? r.json() : { requests: [] }; })
      .then(function(d){ incoming = (d && d.requests) || []; })
      .catch(function(){ incoming = []; });
  }

  function renderRequests(){
    var mine = incoming.filter(function(r){ return r.status === 'pending'; });
    var wrap = document.getElementById('requests-list');
    var emptyMsg = document.getElementById('no-requests');
    wrap.innerHTML = '';

    if(mine.length === 0){
      emptyMsg.style.display = 'block';
      return;
    }
    emptyMsg.style.display = 'none';

    mine.forEach(function(r){
      var row = document.createElement('div');
      row.className = 'req-row';
      row.innerHTML =
        '<div class="req-info"><div class="r-name"></div><div class="r-meta"></div></div>' +
        '<div class="req-actions"><button class="accept-btn">Acceptă</button><button class="decline-btn">Refuză</button></div>';
      row.querySelector('.r-name').textContent = r.memberName + ' → ' + r.teamName;
      row.querySelector('.r-meta').textContent = (r.memberCity || '—') + ' · ' + r.memberEmail + (r.message ? ' · "' + r.message + '"' : '');

      // Accepting is one call. It used to be two local writes -- push a
      // name onto the members list, then mark the request accepted --
      // which could half-happen, and matched the request by member name
      // plus timestamp because there was no id to use. The server does
      // both in one transaction, and a team that filled up in the
      // meantime rolls the whole thing back.
      function decide(verb, btn){
        btn.disabled = true;
        fetch('/api/join-requests/' + r.id + '/' + verb, {
          method: 'POST', credentials: 'same-origin'
        })
          .then(function(resp){ return resp.json().then(function(dd){ return { ok: resp.ok, d: dd }; }); })
          .then(function(rr){
            if(!rr.ok){
              btn.disabled = false;
              row.querySelector('.r-meta').textContent = rr.d.error || 'Nu a mers.';
              return;
            }
            // Re-read both lists: accepting changes the members too.
            return Promise.all([loadRequests(), loadMembers()]).then(function(){
              renderRequests();
              renderMembers();
            });
          })
          .catch(function(){ btn.disabled = false; });
      }

      var acceptBtn = row.querySelector('.accept-btn');
      var declineBtn = row.querySelector('.decline-btn');
      acceptBtn.addEventListener('click', function(){ decide('accept', acceptBtn); });
      declineBtn.addEventListener('click', function(){ decide('reject', declineBtn); });

      wrap.appendChild(row);
    });
  }
  // ---------------------------------------------------------------
  // One bootstrap, rather than each block fetching as it is defined
  // ---------------------------------------------------------------
  // Order matters in exactly one place: a team card lists the members
  // on it, so the members have to be in hand before the teams are
  // drawn. Everything else is independent, so it all goes out at once
  // and the page fills in when the slowest of them answers.
  Promise.all([loadTeams(), loadCategories(), loadMembers(), loadRequests()])
    .then(function(){
      renderCategoryPicker();
      renderMembers();
      renderTeams();
      renderRequests();
    })
    .catch(function(){});

  applyAvatar();

  document.getElementById('avatar-edit-btn').addEventListener('click', function(){
    document.getElementById('avatar-file-input').click();
  });

  document.getElementById('avatar-file-input').addEventListener('change', function(e){
    var file = e.target.files[0];
    if(!file) return;

    var reader = new FileReader();
    reader.onload = function(evt){
      var img = new Image();
      img.onload = function(){
        var size = 160;
        var canvas = document.createElement('canvas');
        canvas.width = size;
        canvas.height = size;
        var ctx = canvas.getContext('2d');

        var minSide = Math.min(img.width, img.height);
        var sx = (img.width - minSide) / 2;
        var sy = (img.height - minSide) / 2;
        ctx.drawImage(img, sx, sy, minSide, minSide, 0, 0, size, size);

        var dataUrl = canvas.toDataURL('image/jpeg', 0.85);

        // The canvas has already cropped this to 160x160 and re-encoded
        // it, so what goes over the wire is a few KB whatever was picked.
        // The server still refuses anything oversized or not an image --
        // this is a browser, and a browser is not where a rule is kept.
        fetch('/api/me/avatar', {
          method: 'PUT',
          credentials: 'same-origin',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ avatar: dataUrl })
        })
          .then(function(r){ return r.json().then(function(d){ return { ok: r.ok, d: d }; }); })
          .then(function(res){
            if(!res.ok){ alert(res.d.error || 'Imaginea nu a putut fi salvată.'); return; }
            // Only after the server has it: showing the new picture on a
            // refusal would tell the person it was saved when it was not.
            avatar = dataUrl;
            applyAvatar();
          })
          .catch(function(){ alert('Imaginea nu a putut fi salvată.'); });
      };
      img.src = evt.target.result;
    };
    reader.readAsDataURL(file);
  });

  document.getElementById('logout-link').addEventListener('click', function(){
    // One call ends the session, whatever the role. Each sign-out page
    // used to clear one key of four, which is why signing out of one
    // role left another signed in.
    fetch('/auth/logout', { method: 'POST', credentials: 'same-origin' })
      .then(function(){ window.location.href = '/'; })
      .catch(function(){ window.location.href = '/'; });
  });
    })
    .catch(function(){
      // With the API unreachable the page shows its signed-out state:
      // it cannot know who is here, and guessing would be worse.
      document.getElementById('not-logged-in').style.display = 'block';
    });
});
}
