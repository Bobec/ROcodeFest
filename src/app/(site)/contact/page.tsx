import type { Metadata } from "next";
import BackButton from "@/components/BackButton";
import FabButtons from "@/components/FabButtons";
import RevealOnScroll from "@/components/RevealOnScroll";
import SiteFooter from "@/components/SiteFooter";
import SiteHeader from "@/components/SiteHeader";
import "./page.css";
import "@/styles/impuls.css";

export const metadata: Metadata = { title: "Contact și sponsori — IMPULS 2027" };

export default function ContactPage() {
  return (
    <>
      <div className="wrap">
        <SiteHeader />
        <BackButton />
        <section className="page-hero">
          <div className="eyebrow">Contact și sponsori</div>
          <h1>Ia legătura cu noi</h1>
          <p>Întrebări despre echipe, evenimente, presă sau parteneriate — ne bucurăm să te auzim.</p>
        </section>
        <section className="section reveal">
          <div className="contact-grid">
            <div className="contact-card">
              <h3>Întrebări generale</h3>
              <p>Echipe, înscriere și logistica evenimentului.</p>
              <a className="email" href="mailto:hello@rocodefest.example">hello@rocodefest.example</a>
            </div>
            <div className="contact-card">
              <h3>Presă și media</h3>
              <p>Interviuri, kit de presă și solicitări de relatare.</p>
              <a className="email" href="mailto:press@rocodefest.example">press@rocodefest.example</a>
            </div>
            <div className="contact-card">
              <h3>📍 Locul finalei</h3>
              <p>Rubik Hub, Aleea Tineretului, Piatra Neamț.</p>
              <a className="email" href="https://www.google.com/maps/search/?api=1&query=Rubik+Hub%2C+Aleea+Tineretului%2C+Piatra+Neam%C8%9B" target="_blank" rel="noopener">Deschide în Google Maps →</a>
            </div>
          </div>
          <div className="sponsor-band reveal" id="sponsors">
            <h2>Sponsorii noștri fondatori</h2>
            <p>Primul sezon IMPULS este posibil datorită sprijinului partenerilor noștri sponsori.</p>
            <div className="sponsor-logos">
              <div className="sponsor-slot">Sponsor 1</div>
              <div className="sponsor-slot">Sponsor 2</div>
              <div className="sponsor-slot">Sponsor 3</div>
              <div className="sponsor-slot">Sponsor 4</div>
            </div>
          </div>
        </section>
        <section className="section reveal" style={{ textAlign: "center" }}>
          <h2 style={{ fontSize: "22px", marginBottom: "10px" }}>Vrei să devii sponsor?</h2>
          <p style={{ color: "var(--ink-soft)", maxWidth: "480px", margin: "0 auto 20px" }}>
            Ajută-ne să finanțăm premiile, kiturile de început și mentoratul pentru echipele fondatoare.
          </p>
          <a className="btn btn-primary" href="/partner">Devino sponsor →</a>
        </section>
        <SiteFooter />
      </div>
      <FabButtons />
      <RevealOnScroll />
    </>
  );
}
