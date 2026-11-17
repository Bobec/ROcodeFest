import type { Metadata } from "next";
import BackButton from "@/components/BackButton";
import ContactForm from "./ContactForm";
import FabButtons from "@/components/FabButtons";
import RevealOnScroll from "@/components/RevealOnScroll";
import SiteFooter from "@/components/SiteFooter";
import SiteHeader from "@/components/SiteHeader";
import "./page.css";
import "@/styles/impuls.css";

export const metadata: Metadata = { title: "Contact — IMPULS 2027" };

export default function ContactPage() {
  return (
    <>
      <div className="wrap">
        <SiteHeader />
        <BackButton />
        <section className="page-hero">
          <div className="eyebrow">Contact</div>
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
        </section>
        <section className="section reveal" id="mesaj">
          <h2 className="contact-form-title">Lasă-ne un mesaj</h2>
          <p className="contact-form-lead">Scrie-ne aici și îți răspundem pe email.</p>
          <ContactForm />
        </section>
        <SiteFooter />
      </div>
      <FabButtons />
      <RevealOnScroll />
    </>
  );
}
