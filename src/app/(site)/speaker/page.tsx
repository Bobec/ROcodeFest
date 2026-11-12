import type { Metadata } from "next";
import BackButton from "@/components/BackButton";
import SiteFooter from "@/components/SiteFooter";
import SiteHeader from "@/components/SiteHeader";
import SpeakerScript from "./PageScript";
import "./page.css";
import "@/styles/impuls.css";

export const metadata: Metadata = { title: "Devino speaker — IMPULS 2027" };

export default function SpeakerPage() {
  return (
    <>
      <div className="wrap">
        <SiteHeader />
        <BackButton />
        <section className="page-hero">
          <div className="eyebrow">Fii speaker la IMPULS</div>
          <h1>Adu echipelor o problemă reală de rezolvat</h1>
          <p>
            Speakerii sunt profesioniști — ingineri, reprezentanți ai fabricilor, experți din industrie — care le prezintă echipelor o provocare reală din compania lor, de rezolvat sau de îmbunătățit.
          </p>
        </section>
        <div className="explainer">
          <p>
            <strong>Ce face un speaker IMPULS:</strong>
            {" "}în locul unei prezentări obișnuite, aduci o problemă reală cu care se confruntă compania ta — ceva la care echipele pot răspunde cu o idee, un design sau o soluție funcțională. Este o ocazie să primești o perspectivă nouă asupra unei provocări reale și să inspiri următoarea generație de ingineri.
          </p>
        </div>
        <div className="perks-row">
          <div className="perk"><div className="emoji-circle">💡</div><p>Primești idei noi pentru o problemă reală</p></div>
          <div className="perk"><div className="emoji-circle">🎤</div><p>Recunoaștere ca speaker</p></div>
          <div className="perk"><div className="emoji-circle">🧑‍🎓</div><p>Acces direct la viitoarele talente</p></div>
        </div>
        <div className="form-card">
          <form id="speaker-form" noValidate>
            <div className="field">
              <label htmlFor="speaker-name">Nume complet *</label>
              {" "}
              <input type="text" id="speaker-name" required placeholder="Numele tău" />
              {" "}
              <span className="error" id="err-speaker-name">Introdu numele.</span>
            </div>
            <div className="field-row">
              <div className="field">
                <label htmlFor="company-name">Numele companiei / fabricii *</label>
                {" "}
                <input type="text" id="company-name" required placeholder="ex. Acme Manufacturing" />
                {" "}
                <span className="error" id="err-company-name">Introdu numele companiei.</span>
              </div>
              <div className="field">
                <label htmlFor="job-title">Funcție</label>
                {" "}
                <input type="text" id="job-title" placeholder="ex. Inginer de proces" />
              </div>
            </div>
            <div className="field">
              <label htmlFor="speaker-email">Email de contact *</label>
              {" "}
              <input type="email" id="speaker-email" required placeholder="tu@exemplu.com" />
              {" "}
              <span className="error" id="err-speaker-email">Introdu un email valid.</span>
            </div>
            {/* A speaker is a partner whose partner_type is 'speaker' -- the
                       enum has had that value all along. So this creates an account,
                       like the partner form does, and an account needs a password.
                       There was none here, and accounts.password_hash is NOT NULL. */}
            <div className="field">
              <label htmlFor="speaker-password">Parolă *</label>
              {" "}
              <input type="password" id="speaker-password" required placeholder="Cel puțin 8 caractere" autoComplete="new-password" />
              {" "}
              <span className="error" id="err-speaker-password">Parola trebuie să aibă cel puțin 8 caractere.</span>
            </div>
            <div className="field">
              <label htmlFor="problem-area">Ce problemă ai aduce echipelor? *</label>
              {" "}
              <textarea id="problem-area" rows={3} required placeholder="Descrie pe scurt provocarea reală la care ai vrea să lucreze echipele" />
              {" "}
              <span className="error" id="err-problem-area">Descrie problema.</span>
            </div>
            <div className="field">
              <label htmlFor="stage-preference">La ce etapă ai vrea să prezinți?</label>
              {" "}
              <select id="stage-preference">
                <option value="City challenge">Proba orașului (local)</option>
                <option value="Final in Piatra Neamț">Finala de la Piatra Neamț</option>
                <option value="Either">Oricare</option>
              </select>
            </div>
            <button type="submit" className="btn btn-primary" style={{ width: "100%" }}>Trimite cererea →</button>
            <p className="form-note">
              Acesta este un formular demo funcțional — vezi nota de mai jos despre cum sunt gestionate cererile.
            </p>
          </form>
          <div id="success-panel" className="success-panel">
            <div className="success-badge">🎤</div>
            <h2 id="success-heading">Mulțumim că te-ai oferit să fii speaker!</h2>
            <p id="success-detail">Te contactăm în curând.</p>
            <a className="btn btn-secondary" href="/contact">Înapoi la contact →</a>
          </div>
        </div>
        <div className="demo-note">
          <p>
            <strong>Cum funcționează acum:</strong>
            {" "}ca și celelalte formulare de pe site, acesta salvează cererile doar în browserul tău, ca demo local. Pentru a primi cereri reale de la speakeri, trebuie conectat la un server comun.
          </p>
        </div>
        <SiteFooter />
      </div>
      <SpeakerScript />
    </>
  );
}
