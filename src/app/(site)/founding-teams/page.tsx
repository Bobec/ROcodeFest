import type { Metadata } from "next";
import BackButton from "@/components/BackButton";
import FoundingTeamsScript from "./PageScript";
import SiteFooter from "@/components/SiteFooter";
import SiteHeader from "@/components/SiteHeader";
import "./page.css";
import "@/styles/impuls.css";

export const metadata: Metadata = { title: "Echipe fondatoare — IMPULS 2027" };

export default function FoundingTeamsPage() {
  return (
    <>
      <div className="wrap">
        <SiteHeader />
        <BackButton />
        <section className="page-hero">
          <div className="eyebrow">Echipe fondatoare</div>
          <h1>Echipele care fac posibil primul sezon</h1>
          <p>Fiecare echipă de aici intră în istoria IMPULS — primele care au concurat vreodată.</p>
        </section>
        <div className="count-banner"><div className="num"><span id="team-count">0</span><p>echipe înscrise</p></div></div>
        <div id="team-list-wrap"><div className="team-grid" id="team-grid"></div></div>
        <div id="empty-state" className="empty-state">
          <h3 style={{ fontSize: "20px" }}>Nicio echipă încă — fii prima</h3>
          <p>Peretele se umple pe măsură ce echipele se înscriu. A ta ar putea fi nr. 1.</p>
          <a className="btn btn-primary" href="/register">Înscrie-ți clubul →</a>
        </div>
        <div className="demo-note">
          <p>
            <strong>Notă:</strong>
            {" "}peretele citește deocamdată din stocarea locală demo a browserului tău, deci arată doar echipele înscrise de pe acest dispozitiv. După ce înscrierea va fi conectată la un server comun, pagina va arăta în timp real toate echipele, de la toți vizitatorii.
          </p>
        </div>
        <SiteFooter />
      </div>
      <FoundingTeamsScript />
    </>
  );
}
