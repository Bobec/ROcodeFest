import type { Metadata } from "next";
import BackButton from "@/components/BackButton";
import CertificatesScript from "./PageScript";
import SiteFooter from "@/components/SiteFooter";
import SiteHeader from "@/components/SiteHeader";
import "./page.css";
import "@/styles/impuls.css";

export const metadata: Metadata = { title: "Diplome — IMPULS 2027" };

export default function CertificatesPage() {
  return (
    <>
      <div className="wrap">
        <SiteHeader />
        <BackButton />
        <section className="page-hero">
          <div className="eyebrow">Rezultatele sezonului</div>
          <h1>Diplomele tale</h1>
          <p>Așa arată o diplomă IMPULS după ce rezultatele devin finale.</p>
        </section>
        <p className="demo-note" id="cert-line" style={{ fontSize: "13px" }}></p>
        <div className="tab-row" id="cert-picker" style={{ justifyContent: "center", display: "none" }}></div>
        <div style={{ textAlign: "center" }}>
          <canvas id="cert-canvas" width="1100" height="780" style={{ maxWidth: "100%", height: "auto", borderRadius: "var(--radius-md)", boxShadow: "0 10px 30px rgba(43,42,40,0.12)" }}></canvas>
          <div style={{ marginTop: "18px" }}><button className="btn btn-secondary" id="download-cert-btn">Descarcă (PNG)</button></div>
        </div>
        <SiteFooter />
      </div>
      <CertificatesScript />
    </>
  );
}
