import type { Metadata } from "next";
import BackButton from "@/components/BackButton";
import FabButtons from "@/components/FabButtons";
import RegisterScript from "./PageScript";
import RevealOnScroll from "@/components/RevealOnScroll";
import SiteFooter from "@/components/SiteFooter";
import SiteHeader from "@/components/SiteHeader";
import "./page.css";
import "@/styles/impuls.css";

export const metadata: Metadata = { title: "Înregistrare — IMPULS 2027" };

export default function RegisterPage() {
  return (
    <>
      <div className="wrap">
        <SiteHeader />
        <BackButton />
        <section className="page-hero" style={{ padding: "30px 0 10px" }}>
          <div className="eyebrow">Înregistrare</div>
          <h1>Înregistrează-ți clubul</h1>
          <p>
            Te înregistrezi o singură dată, ca club — apoi poți adăuga una sau mai multe echipe (Robotică, Programare, Design etc.) din profilul clubului.
          </p>
          <p style={{ fontSize: "14px", marginTop: "10px" }}>
            Vrei să intri într-o echipă existentă în loc să pornești un club?{" "}
            <a href="/join" style={{ color: "var(--coral-dark)", fontWeight: "700", textDecoration: "underline" }}>Intră ca membru →</a>
          </p>
        </section>
        <div id="welcome-back-panel" className="form-card" style={{ display: "none", textAlign: "center" }}>
          <div className="success-badge">👋</div>
          <h2 id="wb-heading">Bine ai revenit!</h2>
          <p id="wb-detail" style={{ color: "var(--ink-soft)", marginBottom: "20px" }}></p>
          <a className="btn btn-primary" href="/profile">Mergi la profilul clubului →</a>
          <p style={{ marginTop: "18px" }}>
            <a href="#" id="logout-link" style={{ fontSize: "13px", color: "var(--ink-soft)", textDecoration: "underline" }}>Nu e clubul tău? Deconectează-te</a>
          </p>
        </div>
        <div className="form-card reveal" id="form-wrap">
          <form id="register-form" noValidate>
            <div className="field">
              <label htmlFor="organization">Numele clubului / organizației / școlii *</label>
              {" "}
              <input type="text" id="organization" required placeholder="ex. CNI Piatra Neamț" />
              {" "}
              <span className="error" id="err-organization">Introdu numele clubului sau al organizației.</span>
            </div>
            <div className="field">
              <label htmlFor="city">Oraș *</label>
              {" "}
              <input type="text" id="city" required placeholder="ex. Cluj-Napoca" />
              {" "}
              <span className="error" id="err-city">Introdu orașul.</span>
            </div>
            <div className="field-row">
              <div className="field">
                <label htmlFor="coach-name">Persoana de contact / coordonatorul *</label>
                {" "}
                <input type="text" id="coach-name" required placeholder="Nume complet" />
                {" "}
                <span className="error" id="err-coach-name">Introdu un nume.</span>
              </div>
              <div className="field">
                <label htmlFor="email">Email de contact *</label>
                {" "}
                <input type="email" id="email" required placeholder="tu@exemplu.com" autoComplete="username" />
                {" "}
                <span className="error" id="err-email">Introdu un email valid.</span>
              </div>
              <div className="field">
                <label htmlFor="password">Parolă *</label>
                {" "}
                <input type="password" id="password" required placeholder="Cel puțin 8 caractere" autoComplete="new-password" />
                {" "}
                <span className="error" id="err-password">Parola trebuie să aibă cel puțin 8 caractere.</span>
              </div>
            </div>
            <div className="field">
              <label htmlFor="notes">Mai e ceva ce ar trebui să știm?</label>
              {" "}
              <textarea id="notes" rows={3} placeholder="Opțional" />
            </div>
            <button type="submit" className="btn btn-primary" style={{ width: "100%" }}>Înregistrează clubul →</button>
            <p className="form-note">
              Acesta este un formular demo funcțional — vezi nota de mai jos despre cum sunt gestionate înscrierile. După înregistrare, îți adaugi echipele din profilul clubului.
            </p>
          </form>
          <div id="success-panel" className="success-panel">
            <div className="success-badge">🎉</div>
            <h2 id="success-heading">Ești înscris!</h2>
            <p id="success-detail">Bine ai venit, club fondator.</p>
            <a className="btn btn-secondary" href="/profile">Adaugă-ți echipele →</a>
          </div>
        </div>
        <div className="demo-note reveal">
          <p>
            <strong>Cum funcționează acum:</strong>
            {" "}formularul salvează datele doar în browserul tău (demo local), deci înscrierile nu sunt încă vizibile altor vizitatori. Pentru un sistem real, comun, de înregistrare, trebuie conectat la un serviciu de formulare sau la o bază de date mică.
          </p>
        </div>
        <SiteFooter />
      </div>
      <FabButtons />
      <RevealOnScroll />
      <RegisterScript />
    </>
  );
}
