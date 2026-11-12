import type { Metadata } from "next";
import BackButton from "@/components/BackButton";
import SiteFooter from "@/components/SiteFooter";
import SiteHeader from "@/components/SiteHeader";
import SubmissionsScript from "./PageScript";
import "./page.css";
import "@/styles/impuls.css";

export const metadata: Metadata = { title: "Lucrări — IMPULS 2027" };

export default function SubmissionsPage() {
  return (
    <>
      <div className="wrap">
        <SiteHeader />
        <BackButton />
        <section className="page-hero">
          <div className="eyebrow">Competiție</div>
          <h1>Lucrările echipei</h1>
          <p>Încarcă aici lucrările pentru proba orașului, înainte de termen.</p>
        </section>
        <div id="no-club" className="card" style={{ textAlign: "center", display: "none" }}>
          <p style={{ color: "var(--ink-soft)" }}>
            Autentifică-te cu contul clubului sau ca membru acceptat într-o echipă ca să trimiți lucrări.
          </p>
          <div className="cta-row" style={{ justifyContent: "center", display: "flex", gap: "12px", flexWrap: "wrap" }}>
            <a className="btn btn-primary" href="/login">Autentifică-te →</a>
            {" "}
            <a className="btn btn-secondary" href="/join">Intră ca membru →</a>
          </div>
        </div>
        <div id="sub-wrap" style={{ display: "none" }}>
          <p className="session-line" id="sub-session-line"></p>
          <div className="card">
            <div className="field">
              <label>Alege echipa</label>
              {" "}
              <select id="sub-team"><option value="">Alege...</option></select>
            </div>
            {/* challenge_id is NOT NULL on submissions, and this form had no
                       challenge field at all -- so nothing it produced could ever have
                       become a row. Filled from the active season, scoped to the
                       chosen team's category. */}
            <div className="field">
              <label>Proba *</label>
              {" "}
              <select id="sub-challenge"><option value="">Alege mai întâi echipa…</option></select>
            </div>
            <div className="field">
              <label>Titlul lucrării *</label>
              <input id="sub-title" placeholder="ex. Proba orașului, runda 1" />
            </div>
            <div className="field">
              <label>Descriere</label>
              <textarea id="sub-desc" rows={3} placeholder="Descrie ce trimiți..." />
            </div>
            <div className="field">
              <label>Link (GitHub, Google Drive etc.)</label>
              <input id="sub-link" placeholder="https://..." />
            </div>
            <button className="btn btn-primary" style={{ width: "100%" }} id="sub-btn">Trimite →</button>
            <p className="error-msg" id="sub-error">Alege o echipă și adaugă un titlu.</p>
          </div>
          <h2 style={{ marginTop: "30px" }}>Lucrările tale</h2>
          <p className="session-line" id="sub-list-hint"></p>
          <div id="sub-list" className="empty-state">Nicio lucrare încă.</div>
        </div>
        <SiteFooter />
      </div>
      <SubmissionsScript />
    </>
  );
}
