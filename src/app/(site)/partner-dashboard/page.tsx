import type { Metadata } from "next";
import BackButton from "@/components/BackButton";
import PartnerDashboardScript from "./PageScript";
import SiteFooter from "@/components/SiteFooter";
import SiteHeader from "@/components/SiteHeader";
import "./page.css";
import "@/styles/impuls.css";

export const metadata: Metadata = { title: "Panoul partenerilor — IMPULS 2027" };

export default function PartnerDashboardPage() {
  return (
    <>
      <div className="wrap">
        <SiteHeader />
        <BackButton />
        <section className="page-hero">
          <div className="eyebrow">Parteneri</div>
          <h1>Panoul partenerilor</h1>
          <p>Urmărește progresul echipelor, statisticile evenimentului și impactul sponsorizării tale.</p>
        </section>
        <div id="no-partner" className="card" style={{ textAlign: "center", display: "none" }}>
          <p style={{ color: "var(--ink-soft)" }}>Autentifică-te cu contul de partener ca să vezi panoul.</p>
          <a className="btn btn-primary" href="/login?tab=partner">Autentificare partener →</a>
          {" "}
          <a className="btn btn-secondary" href="/partner" style={{ marginLeft: "10px" }}>Înscrie-te ca partener →</a>
        </div>
        <div id="pd-wrap" style={{ display: "none" }}>
          <p id="pd-welcome" style={{ textAlign: "center", color: "var(--ink-soft)", fontSize: "14px", marginBottom: "16px" }}></p>
          <p style={{ textAlign: "center", margin: "-10px 0 20px" }}>
            <a href="#" id="partner-logout-link" style={{ fontSize: "12px", textDecoration: "underline", color: "var(--ink-soft)" }}>Deconectează-te</a>
          </p>
          <div className="grid-3" style={{ marginBottom: "24px" }}>
            <div className="card" style={{ textAlign: "center" }}>
              <div className="stat-num" id="pd-clubs" style={{ color: "var(--coral)" }}>0</div>
              <p style={{ fontSize: "13px", color: "var(--ink-soft)" }}>Cluburi înregistrate</p>
            </div>
            <div className="card" style={{ textAlign: "center" }}>
              <div className="stat-num" id="pd-teams" style={{ color: "var(--blue)" }}>0</div>
              <p style={{ fontSize: "13px", color: "var(--ink-soft)" }}>Total echipe</p>
            </div>
            <div className="card" style={{ textAlign: "center" }}>
              <div className="stat-num" id="pd-subs" style={{ color: "var(--green)" }}>0</div>
              <p style={{ fontSize: "13px", color: "var(--ink-soft)" }}>Lucrări</p>
            </div>
          </div>
          <h2>Toate echipele</h2>
          <div className="card" id="pd-teams-list"></div>
        </div>
        <SiteFooter />
      </div>
      <PartnerDashboardScript />
    </>
  );
}
