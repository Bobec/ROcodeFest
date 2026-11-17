"use client";
// The behaviour this page carried as inline <script> blocks, moved here
// unchanged apart from the links (x.html -> /x). It runs once, after
// React has hydrated the markup in page.tsx, and works on that DOM by id.
//
// It is the next thing to rewrite as React state, one page at a time;
// until then it keeps the page doing exactly what it did before.
import { useEffect } from "react";

let started = false;

export default function JoinScript() {
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







  // A read of rocodefest_founding_teams stood here, filling a dropdown
  // this form no longer has -- the team is chosen on /founding-teams
  // afterwards. Nothing ever wrote that key, so it was an empty array
  // assigned to a variable nobody used. Removed rather than pointed at
  // an endpoint: there is nothing here to populate.

  var form = document.getElementById('join-form');
  var fields = {
    'member-name': { el: document.getElementById('member-name'), err: document.getElementById('err-member-name'), validate: function(v){ return v.trim().length > 0; } },
    'member-email': { el: document.getElementById('member-email'), err: document.getElementById('err-member-email'), validate: function(v){ return /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(v.trim()); } },
    'member-city': { el: document.getElementById('member-city'), err: document.getElementById('err-member-city'), validate: function(v){ return v.trim().length > 0; } }
  };

  form.addEventListener('submit', function(e){
    e.preventDefault();
    var allValid = true;

    Object.keys(fields).forEach(function(key){
      var f = fields[key];
      var valid = f.validate(f.el.value);
      if(!valid){
        allValid = false;
        f.el.classList.add('invalid');
        f.err.classList.add('show');
      } else {
        f.el.classList.remove('invalid');
        f.err.classList.remove('show');
      }
    });

    if(!allValid) return;

    var memberName = fields['member-name'].el.value.trim();
    var email = fields['member-email'].el.value.trim();
    var city = fields['member-city'].el.value.trim();
    var message = document.getElementById('member-message').value.trim();

    var password = document.getElementById('member-password').value;
    var pwErr = document.getElementById('err-member-password');
    if(password.length < 8){
      if(pwErr){ pwErr.classList.add('show'); }
      document.getElementById('member-password').classList.add('invalid');
      return;
    }
    if(pwErr){ pwErr.classList.remove('show'); }
    document.getElementById('member-password').classList.remove('invalid');

    // The member account is created in the database. The old version
    // pushed a row into localStorage and checked "is this email already
    // in the list" -- which is not a uniqueness guarantee, only an
    // observation about one browser. uq_accounts_email is the real one.
    var submitBtn = form.querySelector('button[type="submit"]');
    if(submitBtn) submitBtn.disabled = true;
    var emailErr = fields['member-email'].err;

    fetch('/auth/register', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      credentials: 'same-origin',
      body: JSON.stringify({
        role: 'member', email: email, password: password,
        fullName: memberName, city: city, bio: message
      })
    }).then(function(r){
      return r.json().then(function(d){ return { ok: r.ok, data: d }; });
    }).then(function(res){
      if(!res.ok){
        emailErr.textContent = res.data.error || 'Înregistrarea nu a reușit.';
        emailErr.classList.add('show');
        if(submitBtn) submitBtn.disabled = false;
        return;
      }
      document.getElementById('success-heading').textContent = 'Bine ai venit, ' + memberName + '!';
      document.getElementById('success-detail').textContent = 'Acum răsfoiește echipele fondatoare și cere să te alături uneia.';
      form.classList.add('hide');
      document.getElementById('success-panel').classList.add('show');
    }).catch(function(){
      emailErr.textContent = 'Serverul nu răspunde. Încearcă din nou.';
      emailErr.classList.add('show');
      if(submitBtn) submitBtn.disabled = false;
    });
  });
});
}
