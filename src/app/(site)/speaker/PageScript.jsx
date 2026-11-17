"use client";
// The behaviour this page carried as inline <script> blocks, moved here
// unchanged apart from the links (x.html -> /x). It runs once, after
// React has hydrated the markup in page.tsx, and works on that DOM by id.
//
// It is the next thing to rewrite as React state, one page at a time;
// until then it keeps the page doing exactly what it did before.
import { useEffect } from "react";

let started = false;

export default function SpeakerScript() {
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







  var form = document.getElementById('speaker-form');
  var fields = {
    'speaker-name': { el: document.getElementById('speaker-name'), err: document.getElementById('err-speaker-name'), validate: function(v){ return v.trim().length > 0; } },
    'company-name': { el: document.getElementById('company-name'), err: document.getElementById('err-company-name'), validate: function(v){ return v.trim().length > 0; } },
    'speaker-email': { el: document.getElementById('speaker-email'), err: document.getElementById('err-speaker-email'), validate: function(v){ return /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(v.trim()); } },
    'problem-area': { el: document.getElementById('problem-area'), err: document.getElementById('err-problem-area'), validate: function(v){ return v.trim().length > 0; } }
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

    var speakerName = fields['speaker-name'].el.value.trim();
    var companyName = fields['company-name'].el.value.trim();
    var jobTitle = document.getElementById('job-title').value.trim();
    var email = fields['speaker-email'].el.value.trim();
    var problemArea = fields['problem-area'].el.value.trim();
    var stagePreference = document.getElementById('stage-preference').value;

    var password = document.getElementById('speaker-password').value;
    var pwErr = document.getElementById('err-speaker-password');
    if(password.length < 8){
      pwErr.classList.add('show');
      document.getElementById('speaker-password').classList.add('invalid');
      return;
    }
    pwErr.classList.remove('show');
    document.getElementById('speaker-password').classList.remove('invalid');

    // A speaker is a partner whose partner_type is 'speaker'. The
    // application used to be pushed into this browser's own array, so
    // nobody at the festival ever received one -- the form worked
    // perfectly and reached no one.
    //
    // The job title, the problem and the preferred stage have no
    // columns of their own; they go into partners.message, which is
    // what it is for. Inventing three columns for one form would be
    // the wrong direction.
    var message =
      (jobTitle ? 'Funcție: ' + jobTitle + '\n' : '') +
      'Problema propusă: ' + problemArea + '\n' +
      'Etapa preferată: ' + stagePreference;

    var submitBtn = form.querySelector('button[type="submit"]');
    if(submitBtn) submitBtn.disabled = true;
    var emailErr = fields['speaker-email'].err;

    fetch('/auth/register', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      credentials: 'same-origin',
      body: JSON.stringify({
        role: 'partner', email: email, password: password,
        orgName: companyName, contactName: speakerName,
        partnerType: 'speaker', message: message
      })
    })
      .then(function(r){ return r.json().then(function(d){ return { ok: r.ok, data: d }; }); })
      .then(function(res){
        if(!res.ok){
          emailErr.textContent = res.data.error || 'Înscrierea nu a reușit.';
          emailErr.classList.add('show');
          if(submitBtn) submitBtn.disabled = false;
          return;
        }
        document.getElementById('success-heading').textContent = 'Mulțumim, ' + speakerName + '!';
        document.getElementById('success-detail').textContent = 'Cererea ta de speaker din partea ' + companyName + ' a fost primită. Te contactăm la ' + email + '.';
        form.classList.add('hide');
        document.getElementById('success-panel').classList.add('show');
      })
      .catch(function(){
        emailErr.textContent = 'Serverul nu răspunde. Încearcă din nou.';
        emailErr.classList.add('show');
        if(submitBtn) submitBtn.disabled = false;
      });
  });
});
}
