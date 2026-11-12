import type { Metadata } from "next";
import BackButton from "@/components/BackButton";
import FabButtons from "@/components/FabButtons";
import RevealOnScroll from "@/components/RevealOnScroll";
import SiteFooter from "@/components/SiteFooter";
import SiteHeader from "@/components/SiteHeader";
import "./page.css";
import "@/styles/impuls.css";

export const metadata: Metadata = { title: "Participă la IMPULS 2027 — Alege-ți drumul" };

export default function JoinAsPage() {
  return (
    <>
      <div className="wrap">
        <SiteHeader />
        <BackButton />
        <section className="page-hero">
          <div className="eyebrow">Participă</div>
          <h1>Cum vrei să participi la IMPULS?</h1>
          <p>Alege varianta care ți se potrivește — poți reveni oricând să adaugi alta.</p>
        </section>
        <section className="section reveal">
          <div className="join-grid">
            <div className="join-card">
              <div className="icon">🤖</div>
              <h3>Concurent</h3>
              <p>
                Intră într-o echipă existentă sau creează-ți un profil de membru, ca un club să te poată găsi. Să construiești și să concurezi este esența IMPULS.
              </p>
              <a className="btn btn-primary" href="/join">Intră ca membru →</a>
            </div>
            <div className="join-card">
              <div className="icon">🎤</div>
              <h3>Speaker</h3>
              <p>
                Împărtășește-ți experiența cu echipele de elevi — ateliere, prezentări de deschidere sau sesiuni de mentorat în timpul sezonului.
              </p>
              <a className="btn btn-primary" href="/speaker">Înscrie-te ca speaker →</a>
            </div>
            <div className="join-card">
              <div className="icon">🤝</div>
              <h3>Partener</h3>
              <p>
                Sponsorizează premii, kituri de început sau mentorat și ajută la finanțarea unui prim sezon reușit pentru echipele fondatoare.
              </p>
              <a className="btn btn-primary" href="/partner">Înscrie-te ca partener →</a>
            </div>
          </div>
          <p className="club-note">
            Conduci un club sau pregătești un grup de elevi?{" "}
            <a href="/register">Înregistrează-ți clubul →</a>
          </p>
        </section>
        <SiteFooter />
      </div>
      <FabButtons />
      <RevealOnScroll />
    </>
  );
}
