"use client";
// The behaviour this page carried as inline <script> blocks, moved here
// unchanged apart from the links (x.html -> /x). It runs once, after
// React has hydrated the markup in page.tsx, and works on that DOM by id.
//
// It is the next thing to rewrite as React state, one page at a time;
// until then it keeps the page doing exactly what it did before.
import { useEffect } from "react";

let started = false;

export default function JudgeRegisterScript() {
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






  
  var jForm = document.getElementById('judge-form');
  if(jForm) jForm.addEventListener('submit', function(e){
    e.preventDefault();
    var name = document.getElementById('j-name').value.trim();
    var email = document.getElementById('j-email').value.trim();
    if(!name || !email){ document.getElementById('j-error').classList.add('show'); return; }
    var password = document.getElementById('j-password').value;
    var err = document.getElementById('j-error');
    if(password.length < 8){
      err.textContent = 'Parola trebuie să aibă cel puțin 8 caractere.';
      err.classList.add('show');
      return;
    }
    err.classList.remove('show');

    // The judge account goes to the database. It used to be a row in
    // localStorage plus rocodefest_judge_session -- a key no navigation
    // bar read, and one that nothing anywhere cleared, so a signed-in
    // judge was shown as signed out and could not sign out at all.
    // There is one session now and it carries the role.
    fetch('/auth/register', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      credentials: 'same-origin',
      body: JSON.stringify({
        role: 'judge', email: email, password: password, fullName: name,
        expertise: document.getElementById('j-expertise').value.trim(),
        bio: document.getElementById('j-why').value.trim()
      })
    }).then(function(r){
      return r.json().then(function(d){ return { ok: r.ok, data: d }; });
    }).then(function(res){
      if(!res.ok){
        err.textContent = res.data.error || 'Înregistrarea nu a reușit.';
        err.classList.add('show');
        return;
      }
      jForm.style.display = 'none';
      document.getElementById('j-success').style.display = 'block';
      document.getElementById('j-success-msg').textContent = 'Bine ai venit, arbitru ' + name + '!';
    }).catch(function(){
      err.textContent = 'Serverul nu răspunde. Încearcă din nou.';
      err.classList.add('show');
    });
  });
    
});
}
