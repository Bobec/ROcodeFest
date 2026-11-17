"use client";
// The behaviour this page carried as inline <script> blocks, moved here
// unchanged apart from the links (x.html -> /x). It runs once, after
// React has hydrated the markup in page.tsx, and works on that DOM by id.
//
// It is the next thing to rewrite as React state, one page at a time;
// until then it keeps the page doing exactly what it did before.
import { useEffect } from "react";

let started = false;

export default function NewsScript() {
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
  // Published articles only, for everyone. An organiser signed in gets
  // their drafts too -- the endpoint decides that, not this page, so
  // there is no role check here to get wrong.
  function esc(x){ return String(x == null ? "" : x).replace(/</g,"&lt;"); }
  var wrap = document.getElementById("news-list");
  var empty = document.getElementById("news-empty");
  if(!wrap) return;

  fetch("/api/news", { credentials: "same-origin" })
    .then(function(r){ return r.json(); })
    .then(function(d){
      var items = (d && d.news) || [];
      if(items.length === 0){ empty.style.display = "block"; return; }
      wrap.innerHTML = items.map(function(n){
        var when = n.publishedAt
          ? new Date(n.publishedAt).toLocaleDateString(undefined, { day:"numeric", month:"long", year:"numeric" })
          : "ciornă";
        return "<article class=\"news-item reveal visible\">" +
          "<h2>" + esc(n.title) + "</h2>" +
          "<div class=\"news-meta\">" + when + (n.authorName ? " · " + esc(n.authorName) : "") +
            (n.publishedAt ? "" : " · <strong>nepublicat</strong>") + "</div>" +
          (n.summary ? "<p class=\"news-summary\">" + esc(n.summary) + "</p>" : "") +
          "<p class=\"news-body\">" + esc(n.body) + "</p>" +
        "</article>";
      }).join("");
    })
    .catch(function(){
      empty.style.display = "block";
      empty.querySelector("h1").textContent = "Știrile nu au putut fi încărcate";
    });
})();
}
