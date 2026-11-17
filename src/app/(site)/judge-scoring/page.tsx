import type { Metadata } from "next";
import BackButton from "@/components/BackButton";
import JudgeScoringScript from "./PageScript";
import SiteFooter from "@/components/SiteFooter";
import SiteHeader from "@/components/SiteHeader";
import "./page.css";
import "@/styles/impuls.css";

export const metadata: Metadata = { title: "Punctare — IMPULS 2027" };

export default function JudgeScoringPage() {
  return (
    <>
      <div className="wrap">
        <SiteHeader />
        <BackButton />
        <section className="page-hero">
          <div className="eyebrow">Punctare</div>
          <h1>Panoul de punctare al arbitrilor</h1>
          <p>
            Alege o echipă, notează fiecare criteriu și trimite punctajul. Toate punctajele intră în clasamentul live.
          </p>
        </section>
        <div id="no-judge" className="card" style={{ textAlign: "center", display: "none" }}>
          <p style={{ color: "var(--ink-soft)" }}>Ai nevoie de un cont de arbitru ca să punctezi.</p>
          <a className="btn btn-primary" href="/judge-register">Înscrie-te ca arbitru →</a>
        </div>
        <div id="scoring-wrap" style={{ display: "none" }}>
          <div className="card">
            {/* A judge scores a team IN A MATCH. scores.match_id is NOT NULL,
                       and two composite foreign keys decide who may score what: the
                       team must have been in that match, and the judge must be on its
                       panel. This page used to offer every team in the festival with
                       no match at all, so nothing it produced could have become a row. */}
            <div className="field">
              <label>Alege meciul</label>
              {" "}
              <select id="score-match"><option value="">Alege un meci...</option></select>
            </div>
            <div className="field">
              <label>Alege echipa de punctat</label>
              {" "}
              <select id="score-team"><option value="">Alege mai întâi un meci…</option></select>
            </div>
            <div id="rubric">
              <p style={{ fontSize: "13px", fontWeight: "800", margin: "0 0 12px", color: "var(--ink-soft)" }}>GRILA DE PUNCTARE (1-10 pe criteriu)</p>
              <div className="grid-2">
                <div className="field">
                  <label>Inovație</label>
                  <input type="range" min="1" max="10" defaultValue="5" id="s-innovation" />
                  <span id="v-inn" style={{ fontWeight: "800" }}>5</span>
                  /10
                </div>
                <div className="field">
                  <label>Execuție tehnică</label>
                  <input type="range" min="1" max="10" defaultValue="5" id="s-execution" />
                  <span id="v-exe" style={{ fontWeight: "800" }}>5</span>
                  /10
                </div>
                <div className="field">
                  <label>Prezentare</label>
                  <input type="range" min="1" max="10" defaultValue="5" id="s-presentation" />
                  <span id="v-pre" style={{ fontWeight: "800" }}>5</span>
                  /10
                </div>
                <div className="field">
                  <label>Lucru în echipă</label>
                  <input type="range" min="1" max="10" defaultValue="5" id="s-teamwork" />
                  <span id="v-tea" style={{ fontWeight: "800" }}>5</span>
                  /10
                </div>
              </div>
            </div>
            <div className="field">
              <label>Comentariile arbitrului</label>
              <textarea id="s-comment" rows={2} placeholder="Feedback opțional pentru echipă" />
            </div>
            <button className="btn btn-primary" style={{ width: "100%" }} id="submit-score-btn">Trimite punctajul</button>
            <p className="error-msg" id="score-error">Alege mai întâi o echipă.</p>
          </div>
          <h2 style={{ marginTop: "30px" }}>Punctajele trimise de tine</h2>
          <div id="my-scores-list" className="empty-state">Niciun punctaj trimis încă.</div>
        </div>
        <SiteFooter />
      </div>
      <JudgeScoringScript />
    </>
  );
}
