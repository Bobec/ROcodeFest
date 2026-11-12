import type { Metadata } from "next";
import BackButton from "@/components/BackButton";
import LoginScript from "./PageScript";
import SiteFooter from "@/components/SiteFooter";
import SiteHeader from "@/components/SiteHeader";
import "./page.css";
import "@/styles/impuls.css";

export const metadata: Metadata = { title: "Autentificare — IMPULS 2027" };

export default function LoginPage() {
  return (
    <>
      <div className="wrap">
        <SiteHeader hideLogin />
        <BackButton />
        <section className="page-hero">
          <div className="eyebrow">Autentificare</div>
          <h1>Bine ai revenit</h1>
          <p>Intră din nou în contul clubului sau în profilul tău de membru, din acest browser.</p>
        </section>
        <div className="tab-row">
          <button className="tab-btn active" id="tab-club">Cont de club</button>
          {" "}
          <button className="tab-btn" id="tab-member">Cont de membru</button>
          {" "}
          <button className="tab-btn" id="tab-partner">Cont de partener</button>
        </div>
        <div className="form-card" id="club-form-wrap">
          <div className="field">
            <label htmlFor="login-club-name">Numele clubului / organizației</label>
            {" "}
            <input type="text" id="login-club-name" placeholder="ex. CNI Piatra Neamț" />
          </div>
          <div className="field">
            <label htmlFor="login-club-email">Email de contact</label>
            {" "}
            <input type="email" id="login-club-email" placeholder="tu@exemplu.com" autoComplete="username" />
          </div>
          <div className="field">
            <label htmlFor="login-club-password">Parolă</label>
            {" "}
            <input type="password" id="login-club-password" placeholder="Parola ta" autoComplete="current-password" />
          </div>
          <button className="btn btn-primary" id="club-login-btn">Autentifică-te →</button>
          <p className="error-msg" id="club-login-error">Email sau parolă greșită.</p>
        </div>
        <div className="form-card" id="member-form-wrap" style={{ display: "none" }}>
          <div className="field">
            <label htmlFor="login-member-email">Emailul tău</label>
            {" "}
            <input type="email" id="login-member-email" placeholder="tu@exemplu.com" autoComplete="username" />
          </div>
          <div className="field">
            <label htmlFor="login-member-password">Parolă</label>
            {" "}
            <input type="password" id="login-member-password" placeholder="Parola ta" autoComplete="current-password" />
          </div>
          <button className="btn btn-primary" id="member-login-btn">Autentifică-te →</button>
          <p className="error-msg" id="member-login-error">Nu am găsit în acest browser un profil care să se potrivească. Încearcă să creezi unul.</p>
        </div>
        <div className="form-card" id="partner-form-wrap" style={{ display: "none" }}>
          <div className="field">
            <label htmlFor="login-partner-email">Emailul tău de contact</label>
            {" "}
            <input type="email" id="login-partner-email" placeholder="tu@exemplu.com" autoComplete="username" />
          </div>
          <div className="field">
            <label htmlFor="login-partner-password">Parolă</label>
            {" "}
            <input type="password" id="login-partner-password" placeholder="Parola ta" autoComplete="current-password" />
          </div>
          <button className="btn btn-primary" id="partner-login-btn">Autentifică-te →</button>
          <p className="error-msg" id="partner-login-error">
            Nu am găsit în acest browser o cerere de partener care să se potrivească. Încearcă să te înscrii.
          </p>
        </div>
        <div className="limit-note">
          <p>
            <strong>Despre autentificare:</strong>
            {" "}funcționează doar în browserul în care te-ai înregistrat sau ți-ai creat profilul, pentru că acest demo păstrează totul local, în browser, nu pe un server comun. Autentificarea de pe alt calculator nu este încă posibilă — pentru asta site-ul trebuie conectat la un server real.
          </p>
        </div>
        <SiteFooter />
      </div>
      <LoginScript />
    </>
  );
}
