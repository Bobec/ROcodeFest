import type { Metadata } from "next";
import BackButton from "@/components/BackButton";
import PartnerScript from "./PageScript";
import SiteFooter from "@/components/SiteFooter";
import SiteHeader from "@/components/SiteHeader";
import "./page.css";
import "@/styles/impuls.css";

export const metadata: Metadata = { title: "Devino partener — IMPULS 2027" };

export default function PartnerPage() {
  return (
    <>
      <div className="wrap">
        <SiteHeader />
        <BackButton />
        <section className="page-hero">
          <div className="eyebrow">Fii partenerul nostru</div>
          <h1>Ajută la construirea primului sezon</h1>
          <p>
            IMPULS caută parteneri fondatori — sponsori, organizații și speakeri care vor să facă parte dintr-un prim sezon.
          </p>
        </section>
        <div className="perks-row">
          <div className="perk"><div className="emoji-circle">🏷️</div><p>Logo pe site și în ziua evenimentului</p></div>
          <div className="perk"><div className="emoji-circle">📣</div><p>Prezență în materialele de presă</p></div>
          <div className="perk"><div className="emoji-circle">🤝</div><p>Acces direct la echipele fondatoare</p></div>
        </div>
        <div className="form-card">
          <form id="partner-form" noValidate>
            <div className="field">
              <label htmlFor="org-name">Numele organizației / companiei *</label>
              {" "}
              <input type="text" id="org-name" required placeholder="ex. Acme Robotics" />
              {" "}
              <span className="error" id="err-org-name">Introdu numele organizației.</span>
            </div>
            <div className="field-row">
              <div className="field">
                <label htmlFor="contact-name">Persoană de contact *</label>
                {" "}
                <input type="text" id="contact-name" required placeholder="Nume complet" />
                {" "}
                <span className="error" id="err-contact-name">Introdu un nume.</span>
              </div>
              <div className="field">
                <label htmlFor="partner-type">Tipul parteneriatului *</label>
                {" "}
                <select id="partner-type" required>
                  <option value="">Alege</option>
                  <option value="Sponsor">Sponsor</option>
                  <option value="Speaker">Speaker</option>
                  <option value="Media partner">Partener media</option>
                  <option value="Other">Other</option>
                </select>
                {" "}
                <span className="error" id="err-partner-type">Alege o opțiune.</span>
              </div>
            </div>
            <div className="field">
              <label htmlFor="partner-email">Email de contact *</label>
              {" "}
              <input type="email" id="partner-email" required placeholder="tu@exemplu.com" />
            </div>
            <div className="field">
              <label htmlFor="partner-password">Parolă *</label>
              {" "}
              <input type="password" id="partner-password" required placeholder="Cel puțin 8 caractere" autoComplete="new-password" />
              {" "}
              <span className="error" id="err-partner-email">Introdu un email valid.</span>
            </div>
            <div className="field">
              <label htmlFor="partner-message">Spune-ne cum ai vrea să te implici</label>
              {" "}
              <textarea id="partner-message" rows={3} placeholder="Opțional" />
            </div>
            <button type="submit" className="btn btn-primary" style={{ width: "100%" }}>Trimite cererea →</button>
            <p className="form-note">
              Acesta este un formular demo funcțional — vezi nota de mai jos despre cum sunt gestionate cererile.
            </p>
          </form>
          <div id="success-panel" className="success-panel">
            <div className="success-badge">🤝</div>
            <h2 id="success-heading">Mulțumim că ne-ai scris!</h2>
            <p id="success-detail">Te contactăm în curând.</p>
            <a className="btn btn-primary" href="/partner-dashboard">Mergi la panoul tău →</a>
            {" "}
            <a className="btn btn-secondary" href="/contact#sponsors">Vezi partenerii actuali →</a>
          </div>
        </div>
        <div className="demo-note">
          <p>
            <strong>Cum funcționează acum:</strong>
            {" "}ca și formularul de înregistrare, acesta salvează cererile doar în browserul tău, ca demo local. Pentru a primi cereri reale de parteneriat, trebuie conectat la un server comun.
          </p>
        </div>
        <SiteFooter />
      </div>
      <PartnerScript />
    </>
  );
}
