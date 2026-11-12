import type { Metadata } from "next";
import BackButton from "@/components/BackButton";
import EventsScript from "./PageScript";
import FabButtons from "@/components/FabButtons";
import RevealOnScroll from "@/components/RevealOnScroll";
import SiteFooter from "@/components/SiteFooter";
import SiteHeader from "@/components/SiteHeader";
import "./page.css";
import "@/styles/impuls.css";

export const metadata: Metadata = { title: "Evenimente — IMPULS 2027" };

export default function EventsPage() {
  return (
    <>
      <div className="wrap">
        <SiteHeader />
        <BackButton />
        <section className="page-hero">
          <div className="eyebrow">Program și agendă</div>
          <h1>Calendarul sezonului 1</h1>
          <p>Datele-cheie pentru înscriere, proba orașului și finala live de la Piatra Neamț.</p>
        </section>
        <div style={{ maxWidth: "680px", margin: "0 auto 40px" }}>
          <div className="center-card reveal" style={{ textAlign: "left", padding: "24px", marginBottom: "16px" }}>
            <h3 style={{ fontSize: "18px", marginBottom: "12px" }}>📅 Calendarul sezonului</h3>
            {/* Four sentences stood here, two of them reading "TBA" and one
                       naming a date typed by hand. Every one of them is already a date
                       in the database: the season carries its own start and end, and
                       each challenge carries its submission deadline. Nothing on this
                       page is invented any more, and nothing needs editing when a date
                       moves. */}
            <div id="season-timeline" style={{ borderLeft: "3px solid var(--coral)", paddingLeft: "18px" }}></div>
          </div>
          <div className="center-card reveal" style={{ textAlign: "left", padding: "24px", marginBottom: "16px" }}>
            <h3 style={{ fontSize: "18px", marginBottom: "12px" }}>🏟️ Agenda zilei finale</h3>
            {/* A seven-row table stood here and contest-day.html carried a
                       second, longer copy of the same day. Two hand-maintained
                       timetables disagree eventually, and these two already did about
                       when lunch was. Both read /api/schedule now. */}
            <div id="day-agenda" style={{ fontSize: "14px" }}></div>
            <div style={{ textAlign: "right", marginTop: "14px" }}>
              <a className="btn btn-secondary btn-small" href="/contest-day">Programul complet al zilei de concurs →</a>
            </div>
          </div>
          <div className="center-card reveal" style={{ textAlign: "left", padding: "24px" }}>
            <h3 style={{ fontSize: "18px", marginBottom: "8px" }}>📍 Locul finalei</h3>
            <p style={{ fontSize: "14px", color: "var(--ink-soft)", margin: "0 0 10px" }}>Rubik Hub, Aleea Tineretului, Piatra Neamț.</p>
            <a href="https://www.google.com/maps/search/?api=1&query=Rubik+Hub%2C+Aleea+Tineretului%2C+Piatra+Neam%C8%9B" target="_blank" rel="noopener" style={{ fontWeight: "800", color: "var(--coral-dark)", textDecoration: "none", fontSize: "14px" }}>Deschide în Google Maps →</a>
          </div>
        </div>
        <SiteFooter />
      </div>
      <FabButtons />
      <RevealOnScroll />
      <EventsScript />
    </>
  );
}
