import type { Metadata } from "next";
import BackButton from "@/components/BackButton";
import MemberProfileScript from "./PageScript";
import SiteFooter from "@/components/SiteFooter";
import SiteHeader from "@/components/SiteHeader";
import "./page.css";
import "@/styles/impuls.css";

export const metadata: Metadata = { title: "Profilul meu — IMPULS 2027" };

export default function MemberProfilePage() {
  return (
    <>
      <div className="wrap">
        <SiteHeader />
        <BackButton />
        <div id="not-logged-in" className="not-logged-in" style={{ display: "none" }}>
          <h2 style={{ fontSize: "22px" }}>Încă nu ai un profil de membru</h2>
          <p>Creează unul ca să răsfoiești echipele fondatoare și să ceri să te alături.</p>
          <a className="btn btn-primary" href="/join">Creează-ți profilul →</a>
        </div>
        <div id="profile-content" style={{ display: "none" }}>
          <div className="profile-hero">
            <div className="big-avatar" id="p-avatar">?</div>
            <div>
              <h1 id="p-name">Numele membrului</h1>
              <div className="sub" id="p-city-email">Oraș · Email</div>
            </div>
          </div>
          <h2 className="section-title">Datele tale</h2>
          <div className="info-card">
            <div className="info-grid">
              <div className="info-item"><div className="label">Oraș</div><div className="value" id="p-city">—</div></div>
              <div className="info-item"><div className="label">Email</div><div className="value" id="p-email">—</div></div>
              <div className="info-item" style={{ gridColumn: "1/-1" }}>
                <div className="label">Despre tine</div>
                <div className="value" id="p-message" style={{ fontWeight: "600" }}>—</div>
              </div>
            </div>
          </div>
          <h2 className="section-title">Echipe sugerate pentru tine</h2>
          <div id="suggest-wrap">
            <div className="suggest-grid" id="suggest-grid"></div>
            <p className="empty-small" id="no-suggestions" style={{ display: "none" }}>Nicio echipă fondatoare înscrisă încă de pe acest dispozitiv — revino în curând.</p>
          </div>
          <h2 className="section-title">Cererile tale de înscriere</h2>
          <div className="req-list-card">
            <p className="empty-small" id="no-my-requests">Încă nu ai cerut să te alături niciunei echipe.</p>
            <div id="my-requests-list"></div>
          </div>
          <div className="logout-row"><a id="logout-link">Nu ești tu? Deconectează-te</a></div>
        </div>
        <SiteFooter />
      </div>
      <MemberProfileScript />
    </>
  );
}
