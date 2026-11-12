import type { Metadata } from "next";
import BackButton from "@/components/BackButton";
import LeaderboardScript from "./PageScript";
import SiteFooter from "@/components/SiteFooter";
import SiteHeader from "@/components/SiteHeader";
import "./page.css";
import "@/styles/impuls.css";

export const metadata: Metadata = { title: "Clasament — IMPULS 2027" };

export default function LeaderboardPage() {
  return (
    <>
      <div className="wrap">
        <SiteHeader />
        <BackButton />
        <section className="page-hero">
          <div className="eyebrow">Clasament</div>
          <h1>Clasamentul sezonului</h1>
          <p>Clasament live, pe baza punctajelor date de arbitri tuturor echipelor.</p>
        </section>
        <p className="demo-note" id="lb-season-line" style={{ fontSize: "13px" }}></p>
        <div className="tab-row" id="cat-tabs"></div>
        <div className="card" id="lb-card">
          <div id="lb-list" className="empty-state">Niciun punctaj încă. Clasamentul apare aici când arbitrii încep să puncteze.</div>
        </div>
        <SiteFooter />
      </div>
      <LeaderboardScript />
    </>
  );
}
