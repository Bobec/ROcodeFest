import type { Metadata } from "next";
import BackButton from "@/components/BackButton";
import JoinScript from "./PageScript";
import SiteFooter from "@/components/SiteFooter";
import SiteHeader from "@/components/SiteHeader";
import "./page.css";
import "@/styles/impuls.css";

export const metadata: Metadata = { title: "Intră într-o echipă — IMPULS 2027" };

export default function JoinPage() {
  return (
    <>
      <div className="wrap">
        <SiteHeader />
        <BackButton />
        <section className="page-hero">
          <div className="eyebrow">Intră într-o echipă</div>
          <h1>Creează-ți profilul de membru</h1>
          <p>
            Fă-ți rapid un profil, apoi răsfoiește echipele fondatoare și cere să te alături celei care ți se potrivește.
          </p>
        </section>
        <div className="form-card">
          <form id="join-form" noValidate>
            <div className="field">
              <label htmlFor="member-name">Numele tău complet *</label>
              {" "}
              <input type="text" id="member-name" required placeholder="Nume complet" />
              {" "}
              <span className="error" id="err-member-name">Introdu numele.</span>
            </div>
            <div className="field-row">
              <div className="field">
                <label htmlFor="member-email">Email *</label>
                {" "}
                <input type="email" id="member-email" required placeholder="tu@exemplu.com" />
              </div>
              <div className="field">
                <label htmlFor="member-password">Parolă *</label>
                {" "}
                <input type="password" id="member-password" required placeholder="Cel puțin 8 caractere" autoComplete="new-password" />
                {" "}
                <span className="error" id="err-member-email">Introdu un email valid.</span>
              </div>
              <div className="field">
                <label htmlFor="member-city">Orașul tău *</label>
                {" "}
                <input type="text" id="member-city" required placeholder="ex. Cluj-Napoca" />
                {" "}
                <span className="error" id="err-member-city">Introdu orașul.</span>
              </div>
            </div>
            <div className="field">
              <label htmlFor="member-message">Spune-le echipelor câte ceva despre tine</label>
              {" "}
              <textarea id="member-message" rows={3} placeholder="Opțional — abilități, interese, disponibilitate" />
            </div>
            <button type="submit" className="btn btn-primary" style={{ width: "100%" }}>Creează-mi profilul →</button>
            <p className="form-note">
              Acesta este un demo funcțional — vezi nota de mai jos despre cum sunt gestionate profilurile.
            </p>
          </form>
          <div id="success-panel" className="success-panel">
            <div className="success-badge">🙌</div>
            <h2 id="success-heading">Profil creat!</h2>
            <p id="success-detail">Acum răsfoiește echipele fondatoare și cere să te alături uneia.</p>
            <a className="btn btn-secondary" href="/founding-teams">Vezi echipele →</a>
          </div>
        </div>
        <div className="demo-note">
          <p>
            <strong>Cum funcționează acum:</strong>
            {" "}ca și celelalte formulare de pe site, acesta îți salvează profilul doar în browserul tău, ca demo local. După ce l-ai creat, mergi la pagina Echipe fondatoare și cere să te alături unei echipe — cererea va fi legată automat de acest profil.
          </p>
        </div>
        <SiteFooter />
      </div>
      <JoinScript />
    </>
  );
}
