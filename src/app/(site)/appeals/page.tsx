import type { Metadata } from "next";
import AppealsScript from "./PageScript";
import BackButton from "@/components/BackButton";
import SiteFooter from "@/components/SiteFooter";
import SiteHeader from "@/components/SiteHeader";
import "./page.css";
import "@/styles/impuls.css";

export const metadata: Metadata = { title: "Contestații — IMPULS 2027" };

export default function AppealsPage() {
  return (
    <>
      <div className="wrap">
        <SiteHeader />
        <BackButton />
        <section className="page-hero">
          <div className="eyebrow">Ziua competiției</div>
          <h1>Sistemul de contestații</h1>
          <p>
            Fiecare echipă poate depune cel mult 3 contestații pe eveniment. O contestație indică un moment precis din transmisiunea live.
          </p>
        </section>
        <div id="no-club-a" className="card" style={{ textAlign: "center", display: "none" }}>
          <p style={{ color: "var(--ink-soft)" }}>Autentifică-te cu contul clubului ca să depui contestații.</p>
          <a className="btn btn-primary" href="/login">Autentifică-te →</a>
        </div>
        <div id="appeal-wrap" style={{ display: "none" }}>
          <div className="card">
            <div className="field">
              <label>Alege echipa</label>
              {" "}
              <select id="ap-team"><option value="">Alege...</option></select>
            </div>
            <div className="field">
              <label>Momentul din transmisiunea live</label>
              <div className="ts-row">
                <div className="ts-picker">
                  <input type="number" id="ap-ts-h" className="ts-input" min="0" max="23" placeholder="H" />
                  {" "}
                  <span className="ts-sep">:</span>
                  {" "}
                  <input type="number" id="ap-ts-m" className="ts-input" min="0" max="59" placeholder="MM" />
                  {" "}
                  <span className="ts-sep">:</span>
                  {" "}
                  <input type="number" id="ap-ts-s" className="ts-input" min="0" max="59" placeholder="SS" />
                </div>
                <a href="/livestream" target="_blank" rel="noopener" className="btn btn-secondary btn-small">▶ Deschide transmisiunea live</a>
              </div>
            </div>
            <div className="field">
              <label>Împotriva cărui punctaj / cărei decizii</label>
              <input id="ap-target" placeholder="ex. punctajul din runda 2" />
            </div>
            <div className="field">
              <label>Motivul contestației *</label>
              <textarea id="ap-reason" rows={3} placeholder="Explică ce s-a întâmplat și de ce crezi că punctajul sau decizia ar trebui reanalizate..." />
            </div>
            {/* TODO: placeholder — rule codes are a mock taxonomy for visual testing only; official codes + real linking to the regulations will come once the backend is connected. */}
            <div className="field rules-ref-row">
              <div className="field">
                <label>Regula contestată (opțional)</label>
                {" "}
                <select id="ap-rule-code"><option value="">— Nu sunt sigur / altceva —</option></select>
              </div>
              <button type="button" className="btn btn-secondary btn-small" id="ap-ref-rules-btn" title="Doar machetă — va deschide regulamentul oficial după conectarea la server">📖 Vezi regulile</button>
            </div>
            <p className="rule-hint">
              Selector de probă deocamdată — va indica regula exactă (ex. G4, A21, E2…) când regulamentul va veni de pe server.
            </p>
            <button className="btn btn-primary" style={{ width: "100%", marginTop: "14px" }} id="ap-btn">Depune contestația</button>
            <p className="error-msg" id="ap-error"></p>
          </div>
          <h2 style={{ marginTop: "30px" }}>Contestațiile tale</h2>
          <div id="ap-list" className="empty-state">Nicio contestație depusă.</div>
        </div>
        <SiteFooter />
      </div>
      <AppealsScript />
    </>
  );
}
