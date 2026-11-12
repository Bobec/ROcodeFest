"use client";
// The behaviour this page carried as inline <script> blocks, moved here
// unchanged apart from the links (x.html -> /x). It runs once, after
// React has hydrated the markup in page.tsx, and works on that DOM by id.
//
// It is the next thing to rewrite as React state, one page at a time;
// until then it keeps the page doing exactly what it did before.
import { useEffect } from "react";

let started = false;

export default function RegisterScript() {
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
  var form = document.getElementById('register-form');
  if(!form) return;

  var welcomePanel = document.getElementById('welcome-back-panel');
  var formWrap = document.getElementById('form-wrap');

  // Already signed in? Ask the server rather than a localStorage key.
  // Only this panel waits for the answer -- the registration form below
  // works whether or not anyone is signed in, so wrapping the whole page
  // would delay it for nothing.
  fetch('/auth/me', { credentials: 'same-origin' })
    .then(function(r){ return r.json(); })
    .then(function(d){
      var a = d && d.account;
      if(!a || a.role !== 'club') return;

      formWrap.style.display = 'none';
      welcomePanel.style.display = 'block';
      document.getElementById('wb-heading').textContent = 'Bine ai revenit, ' + a.clubName + '!';
      document.getElementById('wb-detail').textContent = "Ești clubul fondator #" + a.foundingNumber + '.';

      document.getElementById('logout-link').addEventListener('click', function(e){
        e.preventDefault();
        // Reload only AFTER the session is actually gone. Firing the
        // request and reloading immediately is a race the old code lost
        // often enough to look intermittent.
        fetch('/auth/logout', { method: 'POST', credentials: 'same-origin' })
          .then(function(){ location.reload(); })
          .catch(function(){ location.reload(); });
      });
    })
    .catch(function(){});

  var fields = {
    'organization': { el: document.getElementById('organization'), err: document.getElementById('err-organization'), validate: function(v){ return v.trim().length > 0; } },
    'city': { el: document.getElementById('city'), err: document.getElementById('err-city'), validate: function(v){ return v.trim().length > 0; } },
    'coach-name': { el: document.getElementById('coach-name'), err: document.getElementById('err-coach-name'), validate: function(v){ return v.trim().length > 0; } },
    'email': { el: document.getElementById('email'), err: document.getElementById('err-email'), validate: function(v){ return /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(v.trim()); } }
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

    var clubName = fields['organization'].el.value.trim();
    var city = fields['city'].el.value.trim();
    var coachName = fields['coach-name'].el.value.trim();
    var email = fields['email'].el.value.trim();
    var notes = document.getElementById('notes').value.trim();

    var password = document.getElementById('password').value;
    var pwErr = document.getElementById('err-password');
    if(password.length < 8){
      pwErr.classList.add('show');
      document.getElementById('password').classList.add('invalid');
      return;
    }
    pwErr.classList.remove('show');
    document.getElementById('password').classList.remove('invalid');

    // The club is created in the database now, not in this browser.
    // Two things the old version got wrong and no longer has to get
    // right: the founding number was computed as "how many clubs I can
    // see, plus one", so two people registering at the same moment would
    // have been given the same one -- it is an identity column on the
    // server. And the account had no password at all.
    var submitBtn = form.querySelector('button[type="submit"]');
    submitBtn.disabled = true;
    var emailErr = document.getElementById('err-email');

    fetch('/auth/register', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        email: email, password: password, clubName: clubName,
        city: city, coachName: coachName, notes: notes
      })
    }).then(function(r){
      return r.json().then(function(data){ return { ok: r.ok, data: data }; });
    }).then(function(res){
      if(!res.ok){
        // A duplicate email and a duplicate club name are both refused by
        // the database, and the message says WHICH -- the person filling
        // in the form needs to know what to change.
        emailErr.textContent = res.data.error || 'Înregistrarea nu a reușit.';
        emailErr.classList.add('show');
        submitBtn.disabled = false;
        return;
      }
      // Registering signs you in, so the session cookie is already set.
      // The founding number is read back from the server rather than
      // guessed, because the server is what assigned it.
      return fetch('/auth/me').then(function(r){ return r.json(); }).then(function(me){
        var n = (me.account && me.account.foundingNumber) || '?';
        document.getElementById('success-heading').textContent = 'Bine ai venit, ' + clubName + '!';
        document.getElementById('success-detail').textContent =
          "Ești clubul fondator #" + n + '. Now add your teams from your club profile.';
        form.classList.add('hide');
        document.getElementById('success-panel').classList.add('show');
      });
    }).catch(function(){
      emailErr.textContent = 'Serverul nu răspunde. Încearcă din nou.';
      emailErr.classList.add('show');
      submitBtn.disabled = false;
    });
  });
});
}
