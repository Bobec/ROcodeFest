import type { Metadata } from "next";
import SiteFooter from "@/components/SiteFooter";
import SiteHeader from "@/components/SiteHeader";
import TeamScript from "./PageScript";
import "./page.css";
import "@/styles/impuls.css";

export const metadata: Metadata = { title: "Echipă — IMPULS 2027" };

export default function TeamPage() {
  return (
    <>
      <div className="wrap">
        <SiteHeader />
        <a className="back-link" id="back-link" href="/founding-teams">← Înapoi la echipe</a>
        <div id="team-content" style={{ display: "none" }}>
          <div className="team-hero">
            <div className="th-top">
              <div>
                <span className="team-cat-badge" id="th-cat">Categorie</span>
                <h1 id="th-name">Numele echipei</h1>
                <div className="sub" id="th-club-line">Club · Oraș</div>
              </div>
              <span className="role-pill" id="th-role-pill" style={{ display: "none" }}></span>
            </div>
            <div className="mini-track" id="th-progress"></div>
          </div>
          <div id="no-access-banner" className="card" style={{ display: "none", textAlign: "center" }}>
            <p style={{ margin: "0 0 6px", fontWeight: "700" }}>Vezi pagina publică a acestei echipe.</p>
            <p className="empty-small" style={{ margin: "0 0 16px" }}>
              Autentifică-te ca clubul acestei echipe sau ca membru acceptat ca să gestionezi lucrările, cererile de înscriere și componența.
            </p>
            <div style={{ display: "flex", gap: "12px", justifyContent: "center", flexWrap: "wrap" }}>
              <a className="btn btn-primary btn-small" href="/login">Autentifică-te ca club →</a>
              {" "}
              <a className="btn btn-secondary btn-small" href="/join">Intră ca membru →</a>
            </div>
          </div>
          <div id="manage-wrap" style={{ display: "none" }}>
            <h2 className="section-title">Lucrări</h2>
            <div className="card">
              <p className="empty-small" id="subs-empty">Nicio lucrare încă pentru această echipă.</p>
              <div id="subs-list"></div>
              <div style={{ textAlign: "right", marginTop: "14px" }}>
                <a className="btn btn-secondary btn-small" id="subs-manage-link" href="/submissions">Trimite / gestionează lucrări →</a>
              </div>
            </div>
            <h2 className="section-title">Cereri de înscriere</h2>
            <div className="card" id="requests-card">
              <p className="empty-small" id="no-requests">Nimeni nu a cerut încă să se alăture acestei echipe.</p>
              <div id="requests-list"></div>
            </div>
            <h2 className="section-title">Membrii echipei</h2>
            <div className="card">
              <div id="members-list"></div>
              <p className="empty-small" id="no-members" style={{ display: "none" }}>Niciun membru în componența echipei încă.</p>
              {/* An "Add to roster" row stood here, collecting a typed-in name
                           and role. Neither was an account: the person named could not
                           sign in, could not submit, and appeared nowhere else on the
                           site, while the member who HAD registered and been accepted
                           was not on the list at all. A team is filled by accepting the
                           join requests above. */}
              <p className="empty-small" style={{ margin: "14px 0 0" }}>Membrii se adaugă acceptând cererile de înscriere de mai sus.</p>
            </div>
            <div id="danger-zone" style={{ display: "none" }}>
              <h2 className="section-title">Zonă periculoasă</h2>
              <div className="card danger-card">
                <p>
                  Ștergerea echipei o elimină din IMPULS împreună cu componența ei. Istoricul lucrărilor și al contestațiilor se păstrează. Acțiunea nu poate fi anulată.
                </p>
                <button className="btn btn-secondary btn-small btn-danger" id="delete-team-btn">🗑 Șterge echipa</button>
              </div>
            </div>
          </div>
        </div>
        <SiteFooter />
      </div>
      <TeamScript />
    </>
  );
}
