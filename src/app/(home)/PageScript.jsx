"use client";
// The behaviour this page carried as inline <script> blocks, moved here
// unchanged apart from the links (x.html -> /x). It runs once, after
// React has hydrated the markup in page.tsx, and works on that DOM by id.
//
// It is the next thing to rewrite as React state, one page at a time;
// until then it keeps the page doing exactly what it did before.
import { useEffect } from "react";

let started = false;

export default function IndexScript() {
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


  var countdownTarget = new Date('2026-11-14T10:00:00');
  function updateCountdown(){
    var now = new Date();
    var diff = countdownTarget - now;
    if(diff <= 0){
      document.getElementById('cd-days').textContent = '0';
      document.getElementById('cd-hours').textContent = '0';
      document.getElementById('cd-mins').textContent = '0';
      document.getElementById('cd-secs').textContent = '0';
      return;
    }
    var days = Math.floor(diff / (1000*60*60*24));
    var hours = Math.floor((diff / (1000*60*60)) % 24);
    var mins = Math.floor((diff / (1000*60)) % 60);
    var secs = Math.floor((diff / 1000) % 60);
    document.getElementById('cd-days').textContent = days;
    document.getElementById('cd-hours').textContent = hours;
    document.getElementById('cd-mins').textContent = mins;
    document.getElementById('cd-secs').textContent = secs;
  }
  if(document.getElementById('countdown')){
    updateCountdown();
    setInterval(updateCountdown, 1000);
  }
});
}
