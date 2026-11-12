import type { Metadata } from "next";
import BackButton from "@/components/BackButton";
import OrganizationsScript from "./PageScript";
import SiteFooter from "@/components/SiteFooter";
import SiteHeader from "@/components/SiteHeader";
import "./page.css";
import "@/styles/impuls.css";

export const metadata: Metadata = { title: "Organizații — IMPULS 2027" };

export default function OrganizationsPage() {
  return (
    <>
      <div className="wrap">
        <SiteHeader />
        <BackButton />
        <section className="page-hero">
          <div className="eyebrow">Organizații</div>
          <h1>Școli și organizații în IMPULS</h1>
          <p>
            Unele organizații aduc mai multe echipe — una de Robotică, una de Programare și altele, toate sub același nume.
          </p>
        </section>
        <div id="org-list"></div>
        <div id="empty-state" className="empty-state" style={{ display: "none" }}>
          <h3 style={{ fontSize: "20px" }}>Nicio organizație încă — fii prima</h3>
          <p>
            După ce echipele se înscriu, organizația lor apare aici, grupată cu celelalte echipe din aceeași școală sau companie.
          </p>
          <a className="btn btn-primary" href="/register">Înscrie-ți clubul →</a>
        </div>
        <div className="demo-note">
          <p>
            <strong>Notă:</strong>
            {" "}ca și peretele echipelor fondatoare, pagina citește deocamdată din stocarea locală demo a browserului tău, deci arată doar organizațiile înscrise de pe acest dispozitiv.
          </p>
        </div>
        <SiteFooter />
      </div>
      <OrganizationsScript />
    </>
  );
}
