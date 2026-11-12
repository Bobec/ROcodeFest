"use client";
// The behaviour this page carried as inline <script> blocks, moved here
// unchanged apart from the links (x.html -> /x). It runs once, after
// React has hydrated the markup in page.tsx, and works on that DOM by id.
//
// It is the next thing to rewrite as React state, one page at a time;
// until then it keeps the page doing exactly what it did before.
import { useEffect } from "react";

let started = false;

export default function ContestDayScript() {
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



  // TODO: provisional — same simple date check as the nav-link gate; the
  // real event window will come from the backend once available. Add
  // ?preview=1 to the URL to view this page outside the event window.
  var pageParams = new URLSearchParams(window.location.search);
  var pagePreview = pageParams.get('preview') === '1';
  var EVENT_DATE = new Date('2026-11-14T00:00:00');
  var pageNow = new Date();
  var pageIsContestDay = pageNow.getFullYear() === EVENT_DATE.getFullYear() && pageNow.getMonth() === EVENT_DATE.getMonth() && pageNow.getDate() === EVENT_DATE.getDate();
  if(pageIsContestDay || pagePreview){
    document.getElementById('not-contest-day').style.display = 'none';
    document.getElementById('contest-day-content').style.display = 'block';
  }




  // The run of show, from the server. Nine items were written into this
  // page as a "sample program", and /events carried a second,
  // shorter copy of the same day -- two hand-maintained timetables that
  // already disagreed with each other about when lunch was.
  //
  // /api/schedule merges two streams: the matches, which carry their own
  // scheduled_at, and the schedule_items an organiser adds for the
  // opening, the breaks and the awards. Matches are not copied into that
  // table, so moving one moves it here with nothing to keep in sync.
  var track = document.getElementById('agenda-track');
  var KIND_LABEL = {
    opening: 'Deschidere', match: 'Meci', break: 'Pauză',
    talk: 'Prezentare', awards: 'Premiere', other: ''
  };

  function hhmm(iso){
    var d = new Date(iso);
    return d.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
  }

  fetch('/api/schedule', { credentials: 'same-origin' })
    .then(function(r){ return r.json(); })
    .then(function(d){
      var items = (d && d.items) || [];
      var head = document.getElementById('agenda-season-line');

      if(items.length === 0){
        // An empty programme and a failed request are different things,
        // and the visitor has to be able to tell which one they got.
        track.innerHTML = '<div class="agenda-item"><div class="agenda-time-col"></div>' +
          '<div class="agenda-dot-col"><div class="agenda-dot"></div></div>' +
          '<div class="agenda-card"><h3>Programul nu este încă publicat</h3>' +
          '<p>Apare aici pe măsură ce organizatorii îl completează.</p></div></div>';
        if(head){ head.textContent = d && d.season ? d.season.name : ''; }
        return;
      }

      if(head && d.season){
        head.textContent = 'Programul zilei · ' + d.season.name;
      }

      track.innerHTML = items.map(function(item){
        var label = KIND_LABEL[item.kind] || '';
        var title = item.title + (item.kind === 'match' && item.matchStatus === 'completed' ? ' ✓' : '');
        var detail = item.detail ||
          (item.kind === 'match'
            ? (item.matchStatus === 'in_progress' ? 'În desfășurare acum.' :
               item.matchStatus === 'completed'   ? 'Încheiat — punctajele intră în clasament.' :
               'Programat.')
            : '');
        var loc = item.location || '';
        return '<div class="agenda-item">' +
          '<div class="agenda-time-col"><div class="agenda-time">' + hhmm(item.startsAt) + '</div></div>' +
          '<div class="agenda-dot-col"><div class="agenda-dot"></div></div>' +
          '<div class="agenda-card"><h3>' + String(title).replace(/</g,'&lt;') + '</h3>' +
          (detail ? '<p>' + String(detail).replace(/</g,'&lt;') + '</p>' : '') +
          (loc ? '<span class="agenda-loc">' + String(loc).replace(/</g,'&lt;') + '</span>' : '') +
          (label ? ' <span class="agenda-loc">' + label + '</span>' : '') +
          '</div></div>';
      }).join('');
    })
    .catch(function(){
      track.innerHTML = '<div class="agenda-item"><div class="agenda-time-col"></div>' +
        '<div class="agenda-dot-col"><div class="agenda-dot"></div></div>' +
        '<div class="agenda-card"><h3>Programul nu a putut fi încărcat</h3>' +
        '<p>Reîncarcă pagina.</p></div></div>';
    });
});
}
