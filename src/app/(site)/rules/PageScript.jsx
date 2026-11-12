"use client";
// The behaviour this page carried as inline <script> blocks, moved here
// unchanged apart from the links (x.html -> /x). It runs once, after
// React has hydrated the markup in page.tsx, and works on that DOM by id.
//
// It is the next thing to rewrite as React state, one page at a time;
// until then it keeps the page doing exactly what it did before.
import { useEffect } from "react";

let started = false;

export default function RulesScript() {
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






  if(window.location.hash){
    var target = document.querySelector(window.location.hash);
    if(target && target.tagName === 'LI'){
      setTimeout(function(){
        target.scrollIntoView({ behavior:'smooth', block:'center' });
        target.classList.add('rule-highlight');
        setTimeout(function(){ target.classList.remove('rule-highlight'); }, 2600);
      }, 150);
    }
  }
});
}
