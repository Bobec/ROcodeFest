import type { Metadata } from "next";
import BackButton from "@/components/BackButton";
import ClubsScript from "./ClubsScript";
import FoundingTeamsScript from "./PageScript";
import SiteFooter from "@/components/SiteFooter";
import SiteHeader from "@/components/SiteHeader";
import "./page.css";
import "@/styles/impuls.css";

// Teams and clubs on one page. They used to be two (/founding-teams and
// /organizations) listing the same teams twice, once on their own and
// once grouped under their club; /organizations now redirects to
// #cluburi here (next.config.ts).
export const metadata: Metadata = { title: "Echipe și cluburi — IMPULS 2027" };

export default function FoundingTeamsPage() {
  return (
    <>
      <div className="wrap">
        <SiteHeader />
        <BackButton />
        <section className="page-hero">
          <div className="eyebrow">Echipe și cluburi</div>
          <h1>Echipele și cluburile care fac posibil primul sezon</h1>
          <p>Fiecare echipă de aici intră în istoria IMPULS — primele care au concurat vreodată.</p>
          {/* a div, not a <nav>: every nav on the site is styled as the header bar */}
          <div className="jump-row">
            <a className="btn btn-secondary btn-small" href="#echipe">Echipe</a>
            <a className="btn btn-secondary btn-small" href="#cluburi">Cluburi</a>
          </div>
        </section>

        <section id="echipe" className="list-section">
          <h2 className="list-title">Echipe</h2>
          <div className="count-banner"><div className="num"><span id="team-count">0</span><p>echipe înscrise</p></div></div>
          <div id="team-list-wrap"><div className="team-grid" id="team-grid"></div></div>
          <div id="empty-state" className="empty-state">
            <h3 style={{ fontSize: "20px" }}>Nicio echipă încă — fii prima</h3>
            <p>Peretele se umple pe măsură ce echipele se înscriu. A ta ar putea fi nr. 1.</p>
            <a className="btn btn-primary" href="/register">Înscrie-ți clubul →</a>
          </div>
        </section>

        <section id="cluburi" className="list-section">
          <h2 className="list-title">Cluburi</h2>
          <p className="list-lead">
            Unele cluburi aduc mai multe echipe — una de Robotică, una de Programare și altele, toate sub același nume.
          </p>
          <div id="org-list"></div>
          <div id="org-empty-state" className="empty-state" style={{ display: "none" }}>
            <h3 style={{ fontSize: "20px" }}>Niciun club încă — fii primul</h3>
            <p>
              După ce echipele se înscriu, clubul lor apare aici, cu toate echipele din aceeași școală sau organizație.
            </p>
            <a className="btn btn-primary" href="/register">Înscrie-ți clubul →</a>
          </div>
        </section>
        <SiteFooter />
      </div>
      <FoundingTeamsScript />
      <ClubsScript />
    </>
  );
}
