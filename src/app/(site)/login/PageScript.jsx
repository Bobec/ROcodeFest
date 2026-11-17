"use client";
// The behaviour this page carried as inline <script> blocks, moved here
// unchanged apart from the links (x.html -> /x). It runs once, after
// React has hydrated the markup in page.tsx, and works on that DOM by id.
//
// It is the next thing to rewrite as React state, one page at a time;
// until then it keeps the page doing exactly what it did before.
import { useEffect } from "react";

let started = false;

export default function LoginScript() {
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






  // Tabs
  var tabClub = document.getElementById('tab-club');
  var tabMember = document.getElementById('tab-member');
  var tabPartner = document.getElementById('tab-partner');
  var clubWrap = document.getElementById('club-form-wrap');
  var memberWrap = document.getElementById('member-form-wrap');
  var partnerWrap = document.getElementById('partner-form-wrap');
  var tabs = [
    { btn: tabClub, wrap: clubWrap },
    { btn: tabMember, wrap: memberWrap },
    { btn: tabPartner, wrap: partnerWrap }
  ];
  function showTab(target){
    tabs.forEach(function(t){
      var active = t.btn === target;
      t.btn.classList.toggle('active', active);
      t.wrap.style.display = active ? 'block' : 'none';
    });
  }
  tabClub.addEventListener('click', function(){ showTab(tabClub); });
  tabMember.addEventListener('click', function(){ showTab(tabMember); });
  tabPartner.addEventListener('click', function(){ showTab(tabPartner); });

  var initialTab = new URLSearchParams(window.location.search).get('tab');
  if(initialTab === 'member'){ showTab(tabMember); }
  else if(initialTab === 'partner'){ showTab(tabPartner); }

  // Signing in
  //
  // All three tabs used to match an email against a list in localStorage:
  // typing any registered address let you in, because there was no
  // password anywhere on the site. They now post to one endpoint, the
  // password is checked against a bcrypt hash on the server, and the
  // session comes back as an httpOnly cookie this page cannot read.
  //
  // One function for all three, because the difference between a club,
  // a member and a partner signing in is which page they land on -- the
  // server works out the role from the account.
  function signIn(btn, emailId, passwordId, errorId, destination){
    var email = document.getElementById(emailId).value.trim();
    var password = document.getElementById(passwordId).value;
    var errEl = document.getElementById(errorId);
    errEl.classList.remove('show');

    if(!email || !password){
      errEl.textContent = 'Completează emailul și parola.';
      errEl.classList.add('show');
      return;
    }

    btn.disabled = true;
    fetch('/auth/login', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      credentials: 'same-origin',
      body: JSON.stringify({ email: email, password: password })
    }).then(function(r){
      return r.json().then(function(data){ return { ok: r.ok, data: data }; });
    }).then(function(res){
      if(res.ok){ window.location.href = destination; return; }
      // The server answers identically for a wrong password and an
      // address that was never registered, so this form cannot be used
      // to find out which emails exist.
      errEl.textContent = res.data.error || 'Email sau parolă greșită.';
      errEl.classList.add('show');
      btn.disabled = false;
    }).catch(function(){
      errEl.textContent = 'Serverul nu răspunde. Încearcă din nou.';
      errEl.classList.add('show');
      btn.disabled = false;
    });
  }

  // Club login
  document.getElementById('club-login-btn').addEventListener('click', function(){
    signIn(this, 'login-club-email', 'login-club-password',
           'club-login-error', '/profile');
  });

  // Member login
  document.getElementById('member-login-btn').addEventListener('click', function(){
    signIn(this, 'login-member-email', 'login-member-password',
           'member-login-error', '/member-profile');
  });

  // Partner login
  document.getElementById('partner-login-btn').addEventListener('click', function(){
    signIn(this, 'login-partner-email', 'login-partner-password',
           'partner-login-error', '/partner-dashboard');
  });


});
}
