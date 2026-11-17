"use client";
// The behaviour this page carried as inline <script> blocks, moved here
// unchanged apart from the links (x.html -> /x). It runs once, after
// React has hydrated the markup in page.tsx, and works on that DOM by id.
//
// It is the next thing to rewrite as React state, one page at a time;
// until then it keeps the page doing exactly what it did before.
import { useEffect } from "react";

let started = false;

export default function CertificatesScript() {
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







  // The drawing below is unchanged -- same layout, same fonts, same
  // border, same signature lines. What changed is where the words come
  // from.
  //
  // A team called Aqua Bot, a club called Acme Robotics and three
  // participants called Alex, Sam and Taylor were written into this
  // page. None of them exist. These are now placeholders for a visitor
  // who is signed out: there is nobody to name, so the canvas says so
  // rather than naming strangers. Anyone signed in gets their own team
  // and their real teammates, and an issued certificate replaces the
  // preview entirely.
  var CERT = {
    teamName: '\u2014',
    clubName: '\u2014',
    category: '\u2014',
    season: 'IMPULS',
    participants: [],
    issued: false,
    serialCode: null
  };

  var canvas = document.getElementById('cert-canvas');
  var ctx = canvas.getContext('2d');

  // Wrapped in a function so it can be redrawn once the real names
  // arrive, instead of the page flashing placeholders and staying that
  // way.
  function draw(){

  ctx.fillStyle = '#FFF9EF'; ctx.fillRect(0,0,1100,780);
  ctx.strokeStyle = '#2B2A28'; ctx.lineWidth = 6;
  ctx.strokeRect(30, 30, 1040, 720);
  ctx.strokeStyle = '#35D400'; ctx.lineWidth = 2;
  ctx.strokeRect(40, 40, 1020, 700);
  // Title
  ctx.fillStyle = '#2B2A28'; ctx.font = '700 42px VT323, sans-serif'; ctx.textAlign = 'center';
  ctx.fillText('CERTIFICAT DE PARTICIPARE', 550, 130);
  // Subtitle
  ctx.fillStyle = '#35D400'; ctx.font = '700 22px VT323, sans-serif';
  ctx.fillText(CERT.season, 550, 175);
  // Decorative line
  ctx.strokeStyle = '#3A3A3A'; ctx.lineWidth = 1; ctx.beginPath(); ctx.moveTo(300,200); ctx.lineTo(800,200); ctx.stroke();
  // This certifies
  ctx.fillStyle = '#6B6660'; ctx.font = '400 16px Jost, sans-serif';
  ctx.fillText('Se certifică faptul că', 550, 260);
  // Team name
  ctx.fillStyle = '#2B2A28'; ctx.font = '800 36px VT323, sans-serif';
  ctx.fillText(CERT.teamName, 550, 320);
  // Club + category
  ctx.fillStyle = '#6B6660'; ctx.font = '600 18px Jost, sans-serif';
  ctx.fillText(CERT.clubName + '  \u00B7  ' + CERT.category, 550, 360);
  // Has completed
  ctx.fillText('a participat cu succes la ' + CERT.season, 550, 420);
  ctx.fillText('Proba orașului și finala — Piatra Neamț', 550, 450);
  // Date
  ctx.font = '400 14px Jost, sans-serif';
  ctx.fillText(new Date().toLocaleDateString('ro-RO', { year:'numeric', month:'long', day:'numeric' }), 550, 520);
  // Participants
  ctx.fillStyle = '#6B6660'; ctx.font = '600 13px Jost, sans-serif';
  ctx.fillText('Participanți: ' + (CERT.participants.length ? CERT.participants.join(', ') : '—'), 550, 560);
  // Signature lines
  ctx.strokeStyle = '#2B2A28'; ctx.lineWidth = 1;
  ctx.beginPath(); ctx.moveTo(200,650); ctx.lineTo(400,650); ctx.stroke();
  ctx.beginPath(); ctx.moveTo(700,650); ctx.lineTo(900,650); ctx.stroke();
  ctx.fillStyle = '#6B6660'; ctx.font = '400 12px Jost, sans-serif';
  ctx.fillText('Organizator', 300, 675);
  ctx.fillText('Arbitru-șef', 800, 675);
  // Sample watermark
  ctx.fillStyle = '#D8D5CE'; ctx.font = '400 10px Jost, sans-serif';
  ctx.textAlign = 'left';
  ctx.fillText(CERT.issued
    ? 'SERIA ' + CERT.serialCode
    : 'PREVIZUALIZARE — NU ESTE O DIPLOMĂ OFICIALĂ', 50, 740);
  ctx.textAlign = 'center';
  }
  draw();


  // ---------------------------------------------------------------
  // The names, from the database
  // ---------------------------------------------------------------
  // Three things can be true, and the page says which one it is
  // rather than drawing the same canvas regardless:
  //
  //   signed out            nobody to name -- placeholders, and a line
  //                         saying to sign in
  //   signed in, none yet   a preview with the viewer own team and
  //                         their real teammates on it
  //   issued                the certificate itself, with its serial
  //                         code in place of the preview watermark
  var line = document.getElementById('cert-line');
  var picker = document.getElementById('cert-picker');

  function apply(c){
    CERT.teamName = c.teamName || '—';
    CERT.clubName = c.clubName || '—';
    CERT.category = c.categoryLabel || '—';
    CERT.season = c.seasonName || 'IMPULS';
    CERT.participants = c.participants || (c.memberName ? [c.memberName] : []);
    CERT.issued = !!c.serialCode;
    CERT.serialCode = c.serialCode || null;
    draw();
  }

  fetch('/api/certificates', { credentials: 'same-origin' })
    .then(function(r){ return r.ok ? r.json() : { certificates: [], preview: null }; })
    .then(function(d){
      var issued = (d && d.certificates) || [];
      var preview = d && d.preview;

      if(issued.length > 0){
        // More than one is normal: a team certificate plus a personal
        // one, or several seasons. They are switched between rather
        // than only the newest being reachable.
        if(issued.length > 1){
          picker.style.display = 'flex';
          picker.innerHTML = issued.map(function(c, i){
            return '<button class="tab-btn' + (i === 0 ? ' active' : '') + '" data-cert="' + i + '">' +
              (c.memberName ? c.memberName : c.teamName) + ' · ' + c.seasonName + '</button>';
          }).join('');
          picker.querySelectorAll('[data-cert]').forEach(function(b){
            b.addEventListener('click', function(){
              picker.querySelectorAll('.tab-btn').forEach(function(x){ x.classList.remove('active'); });
              b.classList.add('active');
              apply(issued[parseInt(b.getAttribute('data-cert'), 10)]);
            });
          });
        }
        apply(issued[0]);
        line.innerHTML = '<strong>Certificat emis.</strong> Codul de serie de pe diplomă îl face verificabil.';
        return;
      }

      if(preview){
        apply(preview);
        line.innerHTML = '<strong>Previzualizare.</strong> Așa va arăta diploma echipei tale — ' +
          'numele sunt cele reale, dar certificatul nu a fost încă emis.';
        return;
      }

      draw();
      line.innerHTML = '<strong>Previzualizare.</strong> ' +
        '<a href="/login" style="text-decoration:underline;">Autentifică-te</a> ' +
        'ca să vezi diploma cu numele echipei tale.';
    })
    .catch(function(){
      draw();
      line.textContent = 'Diplomele nu au putut fi încărcate.';
    });

  document.getElementById('download-cert-btn').addEventListener('click', function(){
    var link = document.createElement('a');
    link.href = canvas.toDataURL('image/png');
    link.download = CERT.issued
      ? 'IMPULS_' + CERT.serialCode + '.png'
      : 'IMPULS_Preview.png';
    link.click();
  });

});
}
