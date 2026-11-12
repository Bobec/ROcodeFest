import type { Metadata } from "next";
import BackButton from "@/components/BackButton";
import FabButtons from "@/components/FabButtons";
import ProfileScript from "./PageScript";
import SiteFooter from "@/components/SiteFooter";
import SiteHeader from "@/components/SiteHeader";
import "./page.css";
import "@/styles/impuls.css";

export const metadata: Metadata = { title: "Clubul meu — IMPULS 2027" };

export default function ProfilePage() {
  return (
    <>
      <div className="wrap">
        <SiteHeader />
        <BackButton />
        <div id="not-logged-in" className="not-logged-in" style={{ display: "none" }}>
          <h2 style={{ fontSize: "22px" }}>Nu ești autentificat</h2>
          <p>
            Înregistrează un club ca să primești propria pagină de profil, unde poți adăuga echipe, urmări progresul sezonului și gestiona cererile de înscriere.
          </p>
          <a className="btn btn-primary" href="/register">Înscrie-ți clubul →</a>
        </div>
        <div id="profile-content" style={{ display: "none" }}>
          <div className="profile-hero">
            <div className="avatar-wrap">
              <div className="big-avatar" id="p-avatar">?</div>
              <div className="avatar-edit-btn" id="avatar-edit-btn" title="Schimbă fotografia clubului">📷</div>
              <input type="file" id="avatar-file-input" accept="image/*" style={{ display: "none" }} />
            </div>
            <div><h1 id="p-team-name">Numele clubului</h1><div className="sub" id="p-org-city">Oraș</div></div>
          </div>
          <h2 className="section-title">Echipele tale</h2>
          <div id="teams-list"></div>
          <div className="add-team-card">
            <p className="add-team-title">✨ Adaugă o echipă nouă</p>
            <p className="field-label">Numele echipei</p>
            <div className="icon-input">
              <span className="icon-input-glyph">🏷️</span>
              {" "}
              <input type="text" id="new-team-name" placeholder="ex. Circuit Breakers" />
            </div>
            <p className="field-label">Categorie</p>
            {/* Filled from /api/teams/categories rather than written out here.
                       Four chips were hardcoded, and a category added to the table
                       would not have appeared, while one removed would still have been
                       offered and the insert refused. */}
            <div className="cat-picker" id="cat-picker"></div>
            <p className="field-label">Cod de participare</p>
            <div className="icon-input">
              <span className="icon-input-glyph">#️⃣</span>
              {" "}
              <input type="text" id="new-team-code" placeholder="ex. CB-2026" />
            </div>
            {/* A "Participants" tag box stood here, collecting typed-in names.
                       They were not accounts and appeared nowhere else on the site. A
                       team is filled by accepting join requests. */}
            <p className="error" id="add-team-error" style={{ display: "none", color: "var(--coral-dark)", fontSize: "13px", fontWeight: "700", marginTop: "10px" }}></p>
            <button className="btn btn-primary btn-small" id="add-team-btn">✚ Adaugă echipa</button>
          </div>
          <h2 className="section-title">Datele clubului</h2>
          <div className="progress-card">
            <div className="info-grid">
              <div className="info-item"><div className="label">Coordonator</div><div className="value" id="p-coach">—</div></div>
              <div className="info-item"><div className="label">Email de contact</div><div className="value" id="p-email">—</div></div>
              <div className="info-item">
                <div className="label">Număr de fondator</div>
                <div className="value" id="p-number">—</div>
              </div>
              <div className="info-item"><div className="label">Total echipe</div><div className="value" id="p-team-count">0</div></div>
            </div>
          </div>
          <h2 className="section-title">Membrii clubului</h2>
          <div className="members-card">
            <div id="members-list"></div>
            {/* A "Member name / Role / Add" row stood here. It wrote a typed-in
                       name into this browser's own localStorage, and that was all it
                       did: the person named could not sign in, could not submit, and
                       appeared nowhere else on the site. A member is an account now,
                       and joins a team by asking -- so the way to add one is to accept
                       the request below, and there is nothing to type here. */}
            <p className="empty-small" style={{ margin: "14px 0 0" }}>Membrii se adaugă acceptând cererile de înscriere de mai jos.</p>
          </div>
          <h2 className="section-title">Cereri de înscriere</h2>
          <div className="requests-card" id="requests-card">
            <p className="empty-small" id="no-requests">Nimeni nu a cerut încă să se alăture echipelor tale.</p>
            <div id="requests-list"></div>
          </div>
          <div className="logout-row"><a id="logout-link">Nu e clubul tău? Deconectează-te</a></div>
        </div>
        <SiteFooter />
      </div>
      <FabButtons labels />
      <ProfileScript />
    </>
  );
}
