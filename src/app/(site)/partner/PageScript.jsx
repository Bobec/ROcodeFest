"use client";
// The behaviour this page carried as inline <script> blocks, moved here
// unchanged apart from the links (x.html -> /x). It runs once, after
// React has hydrated the markup in page.tsx, and works on that DOM by id.
//
// It is the next thing to rewrite as React state, one page at a time;
// until then it keeps the page doing exactly what it did before.
import { useEffect } from "react";

let started = false;

export default function PartnerScript() {
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







  var form = document.getElementById('partner-form');
  var fields = {
    'org-name': { el: document.getElementById('org-name'), err: document.getElementById('err-org-name'), validate: function(v){ return v.trim().length > 0; } },
    'contact-name': { el: document.getElementById('contact-name'), err: document.getElementById('err-contact-name'), validate: function(v){ return v.trim().length > 0; } },
    'partner-type': { el: document.getElementById('partner-type'), err: document.getElementById('err-partner-type'), validate: function(v){ return v.trim().length > 0; } },
    'partner-email': { el: document.getElementById('partner-email'), err: document.getElementById('err-partner-email'), validate: function(v){ return /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(v.trim()); } }
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

    var orgName = fields['org-name'].el.value.trim();
    var contactName = fields['contact-name'].el.value.trim();
    var partnerType = fields['partner-type'].el.value;
    var email = fields['partner-email'].el.value.trim();
    var message = document.getElementById('partner-message').value.trim();

    var password = document.getElementById('partner-password').value;
    var errEl = document.getElementById('err-partner-email') ||
                document.querySelector('.error') ;
    if(password.length < 8){
      if(errEl){
        errEl.textContent = 'Parola trebuie să aibă cel puțin 8 caractere.';
        errEl.classList.add('show');
      }
      document.getElementById('partner-password').classList.add('invalid');
      return;
    }
    document.getElementById('partner-password').classList.remove('invalid');

    // partner_type is an enum in the schema, so a value outside it is
    // refused there rather than checked here -- and comes back as a 400
    // with a message, not a 500.
    fetch('/auth/register', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      credentials: 'same-origin',
      body: JSON.stringify({
        role: 'partner', email: email, password: password,
        orgName: orgName, contactName: contactName,
        partnerType: String(partnerType).toLowerCase(), message: message
      })
    }).then(function(r){
      return r.json().then(function(d){ return { ok: r.ok, data: d }; });
    }).then(function(res){
      if(!res.ok){
        if(errEl){
          errEl.textContent = res.data.error || 'Înregistrarea nu a reușit.';
          errEl.classList.add('show');
        }
        return;
      }
      document.getElementById('success-heading').textContent = 'Mulțumim, ' + orgName + '!';
      document.getElementById('success-detail').textContent = 'Cererea ta a fost primită. Te contactăm la ' + email + '.';
      form.classList.add('hide');
      document.getElementById('success-panel').classList.add('show');
    }).catch(function(){
      if(errEl){
        errEl.textContent = 'Serverul nu răspunde. Încearcă din nou.';
        errEl.classList.add('show');
      }
    });
  });
});
}
