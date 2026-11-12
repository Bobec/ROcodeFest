"use client";
// The behaviour this page carried as inline <script> blocks, moved here
// unchanged apart from the links (x.html -> /x). It runs once, after
// React has hydrated the markup in page.tsx, and works on that DOM by id.
//
// It is the next thing to rewrite as React state, one page at a time;
// until then it keeps the page doing exactly what it did before.
import { useEffect } from "react";

let started = false;

export default function EventsScript() {
  useEffect(() => {
    if (started) return;
    started = true;
    run();
  }, []);
  return null;
}

function run() {
const onReady = (fn) => fn();

(function(){
  // The timeline and the agenda, both from /api/schedule. The endpoint
  // returns the active season, the challenge deadlines as milestones,
  // and the merged run of show -- so this page and /contest-day
  // cannot drift apart, because there is only one source.
  function esc(x){ return String(x == null ? "" : x).replace(/</g,"&lt;"); }
  function day(iso){
    return iso ? new Date(iso).toLocaleDateString(undefined, { day:"numeric", month:"long", year:"numeric" }) : "";
  }
  function hhmm(iso){
    return new Date(iso).toLocaleTimeString([], { hour:"2-digit", minute:"2-digit" });
  }

  var tl = document.getElementById("season-timeline");
  var ag = document.getElementById("day-agenda");
  if(!tl || !ag) return;

  fetch("/api/schedule", { credentials: "same-origin" })
    .then(function(r){ return r.json(); })
    .then(function(d){
      if(!d || !d.season){
        tl.innerHTML = "<p style=\"font-size:14px; color:var(--ink-soft); margin:0;\">Niciun sezon activ momentan.</p>";
        ag.innerHTML = "";
        return;
      }

      var rows = [];
      rows.push({ color:"var(--coral-dark)", label:"Înscrierile se deschid",
                  text: day(d.season.startDate) + " — cluburile și echipele se pot înregistra." });
      (d.milestones || []).forEach(function(m){
        rows.push({
          color: m.stage === "final" ? "var(--coral)" : "var(--blue)",
          label: m.name,
          text: day(m.deadline) + " — termenul de trimitere."
        });
      });
      if(d.season.endDate){
        rows.push({ color:"var(--green)", label:"Sezonul se încheie", text: day(d.season.endDate) + "." });
      }

      tl.innerHTML = rows.map(function(r, i){
        return "<div style=\"margin-bottom:" + (i === rows.length - 1 ? "0" : "18px") + ";\">" +
          "<strong style=\"color:" + r.color + ";\">" + esc(r.label) + "</strong><br>" +
          "<span style=\"font-size:14px; color:var(--ink-soft);\">" + esc(r.text) + "</span></div>";
      }).join("");

      var items = d.items || [];
      if(items.length === 0){
        ag.innerHTML = "<p style=\"color:var(--ink-soft); margin:0;\">Programul zilei nu este încă publicat.</p>";
        return;
      }
      ag.innerHTML = "<table style=\"width:100%; font-size:14px; border-collapse:collapse;\">" +
        items.map(function(it, i){
          var last = i === items.length - 1;
          return "<tr" + (last ? "" : " style=\"border-bottom:1px solid #353535;\"") + ">" +
            "<td style=\"padding:8px 0; font-weight:700; width:100px;\">" + hhmm(it.startsAt) + "</td>" +
            "<td style=\"padding:8px 0;\">" + esc(it.title) +
            (it.location ? " <span style=\"color:var(--ink-soft);\">· " + esc(it.location) + "</span>" : "") +
            "</td></tr>";
        }).join("") + "</table>";
    })
    .catch(function(){
      tl.innerHTML = "<p style=\"font-size:14px; color:var(--ink-soft); margin:0;\">Datele nu au putut fi încărcate.</p>";
    });
})();
}
