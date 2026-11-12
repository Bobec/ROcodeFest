import type { Metadata } from "next";
import AdminScript from "./PageScript";
import BackButton from "@/components/BackButton";
import SiteFooter from "@/components/SiteFooter";
import SiteHeader from "@/components/SiteHeader";
import "./page.css";
import "@/styles/impuls.css";

export const metadata: Metadata = { title: "Panou organizatori — IMPULS 2027" };

export default function AdminPage() {
  return (
    <>
      <div className="wrap">
        <SiteHeader />
        <BackButton />
        <section className="page-hero">
          <div className="eyebrow">Organizatori</div>
          <h1>Panoul concursului</h1>
          <p>
            Sezoane, probe, meciuri și comisii. Ce se creează aici este ce văd cluburile, arbitrii și publicul.
          </p>
        </section>
        {/* Everything below is hidden until /auth/me says this is an organiser.
               The server refuses every /api/admin route to anyone else regardless,
               so this is not the check -- it is what stops the page from drawing a
               panel of controls that would all answer 403. */}
        <div id="not-organizer" className="card" style={{ textAlign: "center", display: "none" }}>
          <p style={{ color: "var(--ink-soft)" }}>Această pagină este pentru organizatori.</p>
          <p style={{ color: "var(--ink-soft)", fontSize: "13px" }}>
            Conturile de organizator nu se creează dintr-un formular — cere unuia existent să îți facă unul.
          </p>
          <a className="btn btn-primary" href="/login">Autentifică-te →</a>
        </div>
        <div id="admin-wrap" style={{ display: "none" }}>
          <p className="session-line" id="admin-session-line"></p>
          <div className="tab-row" id="admin-tabs">
            <button className="tab-btn active" data-panel="seasons">Sezoane</button>
            {" "}
            <button className="tab-btn" data-panel="challenges">Probe</button>
            {" "}
            <button className="tab-btn" data-panel="matches">Meciuri</button>
            {" "}
            <button className="tab-btn" data-panel="schedule">Program</button>
            {" "}
            <button className="tab-btn" data-panel="news">Știri</button>
            {" "}
            <button className="tab-btn" data-panel="organizers">Organizatori</button>
          </div>
          {/* ============================ SEZOANE ============================ */}
          <div className="admin-panel" id="panel-seasons">
            <div className="card">
              <h2 style={{ fontSize: "18px", marginBottom: "14px" }}>Sezon nou</h2>
              <div className="grid-2">
                <div className="field"><label>Nume *</label><input id="se-name" placeholder="ex. Sezonul 1 (2026)" /></div>
                <div className="field"><label>Început *</label><input id="se-start" type="date" /></div>
                <div className="field"><label>Sfârșit</label><input id="se-end" type="date" /></div>
                <div className="field" style={{ display: "flex", alignItems: "flex-end" }}>
                  <label style={{ fontWeight: "700", display: "flex", alignItems: "center", gap: "8px", margin: "0" }}><input type="checkbox" id="se-active" style={{ width: "auto" }} /> Fă-l sezonul activ</label>
                </div>
              </div>
              {/* uq_seasons_single_active is a partial unique index: exactly one
                           season can be active. Ticking this deactivates the current one
                           in the same transaction, rather than failing on the index. */}
              <p style={{ fontSize: "12px", color: "var(--ink-soft)", margin: "0 0 12px" }}>Un singur sezon poate fi activ. Bifând, cel activ acum devine inactiv.</p>
              <button className="btn btn-primary btn-small" id="se-btn">Creează sezonul</button>
              <p className="error-msg" id="se-error"></p>
            </div>
            <div id="seasons-list"></div>
          </div>
          {/* ============================= PROBE ============================= */}
          <div className="admin-panel" id="panel-challenges" style={{ display: "none" }}>
            <div className="card">
              <h2 style={{ fontSize: "18px", marginBottom: "14px" }}>Probă nouă</h2>
              <div className="grid-2">
                <div className="field"><label>Sezon *</label><select id="ch-season"></select></div>
                <div className="field"><label>Nume *</label><input id="ch-name" placeholder="ex. Proba orașului" /></div>
                <div className="field">
                  <label>Etapă *</label>
                  {" "}
                  <select id="ch-stage">
                    <option value="city_challenge">Etapa orașului</option>
                    <option value="final">Finala</option>
                  </select>
                </div>
                <div className="field"><label>Categorie</label><select id="ch-category"></select></div>
                <div className="field"><label>Termen de trimitere</label><input id="ch-deadline" type="datetime-local" /></div>
              </div>
              <div className="field">
                <label>Descriere</label>
                <textarea id="ch-desc" rows={2} placeholder="Ce au de făcut echipele" />
              </div>
              {/* challenges.category_id is nullable and that nullable means
                           "open to every category" -- so the picker offers it rather
                           than making the column's own design unreachable. */}
              <p style={{ fontSize: "12px", color: "var(--ink-soft)", margin: "0 0 12px" }}>Fără categorie, proba este deschisă tuturor categoriilor.</p>
              <button className="btn btn-primary btn-small" id="ch-btn">Creează proba</button>
              <p className="error-msg" id="ch-error"></p>
            </div>
            <div id="challenges-list"></div>
          </div>
          {/* ============================ MECIURI ============================ */}
          <div className="admin-panel" id="panel-matches" style={{ display: "none" }}>
            <div className="card">
              <h2 style={{ fontSize: "18px", marginBottom: "14px" }}>Meci nou</h2>
              <div className="grid-2">
                <div className="field"><label>Proba *</label><select id="ma-challenge"></select></div>
                <div className="field"><label>Runda</label><input id="ma-round" placeholder="ex. Semifinala A" /></div>
                <div className="field"><label>Ora</label><input id="ma-when" type="datetime-local" /></div>
                <div className="field"><label>Locul</label><input id="ma-where" placeholder="ex. Sala Polivalentă" /></div>
              </div>
              <button className="btn btn-primary btn-small" id="ma-btn">Creează meciul</button>
              <p className="error-msg" id="ma-error"></p>
            </div>
            {/* enforce_match_is_playable refuses a score on a match that is not
                       in progress or completed, so the status control below is what
                       actually opens and closes scoring. It is not a label. */}
            <div className="demo-note" style={{ margin: "0 0 16px" }}>
              <p>
                <strong>Starea contează:</strong>
                {" "}arbitrii pot puncta doar un meci „în desfășurare” sau „încheiat”. Clasamentul numără doar meciurile{" "}
                <strong>încheiate</strong>
                , deci el se actualizează în clipa în care marchezi meciul ca încheiat.
              </p>
            </div>
            <div id="matches-list"></div>
          </div>
          {/* ============================ PROGRAM ============================ */}
          <div className="admin-panel" id="panel-schedule" style={{ display: "none" }}>
            <div className="card">
              <h2 style={{ fontSize: "18px", marginBottom: "14px" }}>Intrare în program</h2>
              <div className="grid-2">
                <div className="field">
                  <label>Tip *</label>
                  {" "}
                  <select id="sc-kind">
                    <option value="opening">Deschidere</option>
                    <option value="break">Pauză</option>
                    <option value="talk">Prezentare</option>
                    <option value="awards">Premiere</option>
                    <option value="other">Altceva</option>
                  </select>
                </div>
                <div className="field"><label>Titlu *</label><input id="sc-title" placeholder="ex. Pauza de masă" /></div>
                <div className="field"><label>Început *</label><input id="sc-start" type="datetime-local" /></div>
                <div className="field"><label>Sfârșit</label><input id="sc-end" type="datetime-local" /></div>
                <div className="field"><label>Locul</label><input id="sc-where" placeholder="ex. Foaier" /></div>
              </div>
              {/* Matches are not entered here. They carry their own
                           scheduled_at, and the contest-day page merges both streams by
                           time -- copying a match's time into a second row would create
                           two times that disagree the moment one of them moves. */}
              <p style={{ fontSize: "12px", color: "var(--ink-soft)", margin: "0 0 12px" }}>
                Meciurile nu se adaugă aici — ele își au ora lor și apar automat în program. Aici pui doar ce e între ele: deschiderea, pauzele, premierea.
              </p>
              <button className="btn btn-primary btn-small" id="sc-btn">Adaugă în program</button>
              <p className="error-msg" id="sc-error"></p>
            </div>
            <div id="schedule-list"></div>
          </div>
          {/* ============================= ȘTIRI ============================= */}
          <div className="admin-panel" id="panel-news" style={{ display: "none" }}>
            <div className="card">
              <h2 style={{ fontSize: "18px", marginBottom: "14px" }}>Articol nou</h2>
              <div className="field"><label>Titlu *</label><input id="nw-title" placeholder="ex. S-au deschis înscrierile" /></div>
              <div className="field">
                <label>Rezumat</label>
                <input id="nw-summary" placeholder="O propoziție, afișată în listă" />
              </div>
              <div className="field"><label>Text *</label><textarea id="nw-body" rows={5} /></div>
              {/* published_at is nullable, so a draft is simply a row without a
                           date. No status column, and therefore no rules about which
                           transitions between statuses are legal. */}
              <label style={{ fontWeight: "700", display: "flex", alignItems: "center", gap: "8px", marginBottom: "12px" }}>
                <input type="checkbox" id="nw-publish" style={{ width: "auto" }} defaultChecked />
                {" "}Publică acum
              </label>
              {" "}
              <button className="btn btn-primary btn-small" id="nw-btn">Salvează</button>
              <p className="error-msg" id="nw-error"></p>
            </div>
            <div id="news-list"></div>
          </div>
          {/* ========================== ORGANIZATORI ========================== */}
          <div className="admin-panel" id="panel-organizers" style={{ display: "none" }}>
            <div className="card">
              <h2 style={{ fontSize: "18px", marginBottom: "14px" }}>Organizator nou</h2>
              <div className="grid-2">
                <div className="field"><label>Nume complet *</label><input id="og-name" placeholder="Nume Prenume" /></div>
                <div className="field"><label>Funcție</label><input id="og-title" placeholder="ex. Coordonator arbitraj" /></div>
                <div className="field">
                  <label>Email *</label>
                  <input id="og-email" type="email" placeholder="nume@rocodefest.ro" />
                </div>
                <div className="field">
                  <label>Parolă *</label>
                  <input id="og-password" type="password" placeholder="Cel puțin 8 caractere" autoComplete="new-password" />
                </div>
              </div>
              {/* /auth/register refuses role: 'organizer' outright. A public
                           form that hands out this role is a public form that hands out
                           the festival, so the only way in is from someone already here. */}
              <p style={{ fontSize: "12px", color: "var(--ink-soft)", margin: "0 0 12px" }}>
                Un organizator poate crea sezoane, meciuri și comisii. Nu se poate înregistra nimeni singur cu acest rol.
              </p>
              <button className="btn btn-primary btn-small" id="og-btn">Creează contul</button>
              <p className="error-msg" id="og-error"></p>
            </div>
            <div id="organizers-list"></div>
          </div>
        </div>
        <SiteFooter />
      </div>
      <AdminScript />
    </>
  );
}
