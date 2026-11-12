import type { Metadata } from "next";
import BackButton from "@/components/BackButton";
import JudgeRegisterScript from "./PageScript";
import SiteFooter from "@/components/SiteFooter";
import SiteHeader from "@/components/SiteHeader";
import "./page.css";
import "@/styles/impuls.css";

export const metadata: Metadata = { title: "Devino arbitru — IMPULS 2027" };

export default function JudgeRegisterPage() {
  return (
    <>
      <div className="wrap">
        <SiteHeader />
        <BackButton />
        <section className="page-hero">
          <div className="eyebrow">Arbitri</div>
          <h1>Înscrie-te ca arbitru</h1>
          <p>
            Arbitrii evaluează echipele, punctează rundele și ajută la stabilirea celor care merg în finala de la Piatra Neamț.
          </p>
        </section>
        <div className="card" style={{ maxWidth: "520px", margin: "20px auto" }}>
          <form id="judge-form">
            <div className="field"><label>Nume complet *</label><input id="j-name" required placeholder="Numele tău" /></div>
            <div className="grid-2">
              <div className="field">
                <label>Email *</label>
                <input type="email" id="j-email" required placeholder="tu@exemplu.com" />
              </div>
              <div className="field">
                <label htmlFor="j-password">Parolă *</label>
                {" "}
                <input type="password" id="j-password" required placeholder="Cel puțin 8 caractere" autoComplete="new-password" />
              </div>
              <div className="field"><label>Expertiză</label><input id="j-expertise" placeholder="ex. Robotică, AI" /></div>
            </div>
            <div className="field">
              <label>De ce vrei să arbitrezi</label>
              <textarea id="j-why" rows={3} placeholder="Opțional" />
            </div>
            <button className="btn btn-primary" style={{ width: "100%" }}>Înscrie-te ca arbitru</button>
            <p className="error-msg" id="j-error">Completează numele și emailul.</p>
          </form>
          <div id="j-success" style={{ display: "none", textAlign: "center", padding: "20px 0" }}>
            <p style={{ fontSize: "32px" }}>⚖</p>
            <h2 id="j-success-msg">Cerere primită!</h2>
            <p style={{ color: "var(--ink-soft)" }}>Acum te poți autentifica ca arbitru.</p>
            <a className="btn btn-secondary" href="/judge-scoring">Mergi la panoul de punctare →</a>
          </div>
        </div>
        <div className="demo-note"><p><strong>Demo:</strong> conturile de arbitru sunt stocate local în browserul tău.</p></div>
        <SiteFooter />
      </div>
      <JudgeRegisterScript />
    </>
  );
}
