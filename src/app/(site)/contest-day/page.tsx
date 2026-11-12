import type { Metadata } from "next";
import BackButton from "@/components/BackButton";
import ContestDayScript from "./PageScript";
import SiteFooter from "@/components/SiteFooter";
import SiteHeader from "@/components/SiteHeader";
import "./page.css";
import "@/styles/impuls.css";

export const metadata: Metadata = { title: "Ziua concursului — IMPULS 2027" };

export default function ContestDayPage() {
  return (
    <>
      <div className="wrap">
        <SiteHeader />
        <BackButton />
        <div id="not-contest-day">
          <section className="page-hero">
            <div className="eyebrow">14 noiembrie 2026 · Piatra Neamț</div>
            <h1>Programul zilei de concurs</h1>
            <p>
              Pagina se deblochează în ziua evenimentului. Revino pe 14 noiembrie 2026 — sau vezi până atunci calendarul sezonului.
            </p>
          </section>
          <div className="card" style={{ textAlign: "center", maxWidth: "520px", margin: "0 auto 50px" }}>
            <p style={{ fontSize: "15px", color: "var(--ink-soft)", margin: "0 0 18px" }}>
              Programul minut cu minut al zilei de concurs nu este încă disponibil. Se va debloca aici automat când începe finala.
            </p>
            <a className="btn btn-secondary btn-small" href="/events">📅 Vezi calendarul sezonului</a>
          </div>
        </div>
        <div id="contest-day-content" style={{ display: "none" }}>
          <section className="page-hero">
            <div className="eyebrow">14 noiembrie 2026 · Piatra Neamț</div>
            <h1>Programul zilei de concurs</h1>
            <p>O zi, o arenă — iată cum se desfășoară finala, minut cu minut.</p>
          </section>
          <p className="demo-note" id="agenda-season-line" style={{ fontSize: "13px" }}></p>
          <div className="agenda-track" id="agenda-track"></div>
          <div className="card venue-card">
            <div className="venue-icon">📍</div>
            <div>
              <h3 style={{ fontSize: "17px", marginBottom: "4px" }}>Rubik Hub, Piatra Neamț</h3>
              <p style={{ fontSize: "14px", color: "var(--ink-soft)", margin: "0 0 8px" }}>Aleea Tineretului, Piatra Neamț — porțile se deschid la 07:30.</p>
              <a href="https://www.google.com/maps/search/?api=1&query=Rubik+Hub%2C+Aleea+Tineretului%2C+Piatra+Neam%C8%9B" target="_blank" rel="noopener" style={{ fontWeight: "800", color: "var(--coral-dark)", textDecoration: "none", fontSize: "14px" }}>Deschide în Google Maps →</a>
            </div>
          </div>
          <div style={{ display: "flex", gap: "12px", justifyContent: "center", flexWrap: "wrap", margin: "24px 0 50px" }}>
            <a className="btn btn-secondary btn-small" href="/livestream">▶ Urmărește live</a>
            {" "}
            <a className="btn btn-secondary btn-small" href="/leaderboard">🏆 Clasament</a>
            {" "}
            <a className="btn btn-secondary btn-small" href="/rules">📋 Reguli</a>
            {" "}
            <a className="btn btn-secondary btn-small" href="/events">📅 Calendarul sezonului</a>
          </div>
        </div>
        <SiteFooter />
      </div>
      <ContestDayScript />
    </>
  );
}
