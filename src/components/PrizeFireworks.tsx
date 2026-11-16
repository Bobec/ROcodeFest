"use client";
// Pixel fireworks over the section it is placed in. It draws on a canvas
// that covers its parent (the parent needs position:relative) and fires
// a short show each time the parent scrolls into view, at most once per
// COOLDOWN, and again on a click on any [data-fireworks-trigger] inside
// the parent. Nothing is drawn for visitors who ask for reduced motion.
import { useEffect, useRef } from "react";

const COLORS = ["#35d400", "#7dff4f", "#b6ff9e", "#f2efea", "#ffd84a"];
const COOLDOWN = 8000;
const PX = 4; // the size of one "pixel" of the explosion, in CSS px

// A rocket flies from y0 to ty in `dur` seconds on a fixed curve, so it
// always arrives and bursts, whatever the screen's refresh rate.
type Rocket = { x: number; y0: number; ty: number; t: number; dur: number; color: string };
type Spark = { x: number; y: number; vx: number; vy: number; life: number; max: number; color: string };

export default function PrizeFireworks() {
  const ref = useRef<HTMLCanvasElement>(null);

  useEffect(() => {
    const canvas = ref.current;
    const host = canvas?.parentElement;
    const ctx = canvas?.getContext("2d");
    if (!canvas || !host || !ctx) return;
    if (window.matchMedia("(prefers-reduced-motion: reduce)").matches) return;

    let w = 0, h = 0, raf = 0, last = 0, lastShow = -Infinity;
    const rockets: Rocket[] = [];
    const sparks: Spark[] = [];
    const timers: number[] = [];

    const resize = () => {
      const r = canvas.getBoundingClientRect();
      const dpr = Math.min(window.devicePixelRatio || 1, 2);
      w = r.width; h = r.height;
      canvas.width = Math.round(w * dpr);
      canvas.height = Math.round(h * dpr);
      ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
      ctx.imageSmoothingEnabled = false;
    };

    const pick = () => COLORS[Math.floor(Math.random() * COLORS.length)];

    const launch = () => {
      rockets.push({
        x: w * (0.15 + Math.random() * 0.7),
        y0: h,
        ty: h * (0.08 + Math.random() * 0.3),
        t: 0,
        dur: 0.8 + Math.random() * 0.35,
        color: pick(),
      });
      if (!raf) { last = performance.now(); raf = requestAnimationFrame(frame); }
    };

    const burst = (x: number, y: number, color: string) => {
      const n = 60 + Math.floor(Math.random() * 25);
      const speed = Math.min(w, 900) * (0.28 + Math.random() * 0.14);
      for (let i = 0; i < n; i++) {
        const a = (i / n) * Math.PI * 2 + Math.random() * 0.2;
        const s = speed * (0.35 + Math.random() * 0.65);
        const max = 0.9 + Math.random() * 0.6;
        sparks.push({
          x, y, vx: Math.cos(a) * s, vy: Math.sin(a) * s, life: max, max,
          color: Math.random() < 0.25 ? "#f2efea" : color,
        });
      }
    };

    const snap = (v: number) => Math.round(v / PX) * PX;

    const frame = (now: number) => {
      const dt = Math.min((now - last) / 1000, 0.05);
      last = now;
      ctx.clearRect(0, 0, w, h);

      for (let i = rockets.length - 1; i >= 0; i--) {
        const r = rockets[i];
        r.t += dt;
        const p = Math.min(r.t / r.dur, 1);
        const y = r.y0 + (r.ty - r.y0) * (1 - Math.pow(1 - p, 3)); // eases out at the top
        if (p >= 1) { burst(r.x, y, r.color); rockets.splice(i, 1); continue; }
        ctx.fillStyle = r.color;
        ctx.fillRect(snap(r.x), snap(y), PX, PX * 2);
        ctx.globalAlpha = 0.4;
        ctx.fillRect(snap(r.x), snap(y) + PX * 3, PX, PX);
        ctx.globalAlpha = 1;
      }

      for (let i = sparks.length - 1; i >= 0; i--) {
        const s = sparks[i];
        s.life -= dt;
        if (s.life <= 0) { sparks.splice(i, 1); continue; }
        const drag = Math.pow(0.12, dt); // loses 88% of its speed per second
        s.vx *= drag; s.vy = s.vy * drag + 110 * dt;
        s.x += s.vx * dt; s.y += s.vy * dt;
        const t = s.life / s.max;
        // a pixel firework does not fade smoothly: it flickers out
        if (t < 0.35 && Math.random() < 0.4) continue;
        ctx.globalAlpha = Math.min(1, t * 1.6);
        ctx.fillStyle = s.color;
        ctx.fillRect(snap(s.x), snap(s.y), PX, PX);
      }
      ctx.globalAlpha = 1;

      if (rockets.length || sparks.length) raf = requestAnimationFrame(frame);
      else { raf = 0; ctx.clearRect(0, 0, w, h); }
    };

    const show = (force = false) => {
      const now = performance.now();
      if (!force && now - lastShow < COOLDOWN) return;
      lastShow = now;
      const count = 8;
      for (let i = 0; i < count; i++) timers.push(window.setTimeout(launch, i * 340 + Math.random() * 200));
    };

    resize();
    const ro = new ResizeObserver(resize);
    ro.observe(canvas);

    const io = new IntersectionObserver((entries) => {
      if (entries.some((e) => e.isIntersecting)) show();
    }, { threshold: 0.45 });
    io.observe(host);

    const onClick = (e: MouseEvent) => {
      if ((e.target as Element).closest("[data-fireworks-trigger]")) show(true);
    };
    host.addEventListener("click", onClick);

    return () => {
      ro.disconnect();
      io.disconnect();
      host.removeEventListener("click", onClick);
      timers.forEach(clearTimeout);
      cancelAnimationFrame(raf);
    };
  }, []);

  return <canvas ref={ref} className="fireworks-canvas" aria-hidden="true" />;
}
