import type { Metadata } from "next";
import BackButton from "@/components/BackButton";
import FabButtons from "@/components/FabButtons";
import RevealOnScroll from "@/components/RevealOnScroll";
import RulesScript from "./PageScript";
import SiteFooter from "@/components/SiteFooter";
import SiteHeader from "@/components/SiteHeader";
import HideForClub from "@/components/HideForClub";
import "./page.css";
import "@/styles/impuls.css";

export const metadata: Metadata = { title: "Reguli și joc — IMPULS 2027" };

export default function RulesPage() {
  return (
    <>
      <div className="wrap">
        <SiteHeader />
        <BackButton />
        <section className="page-hero">
          <div className="eyebrow">Reguli și joc</div>
          <h1>Cum funcționează, de fapt, competiția</h1>
          <p>Două etape, o probă identică pentru toți și o finală live care decide câștigătorii.</p>
        </section>
        <section className="section reveal">
          <h2>Cele două etape</h2>
          <div className="stage-grid">
            <div className="stage-card">
              <div className="num">1</div>
              <h3>Proba orașului</h3>
              <p>
                Fiecare echipă îndeplinește exact aceeași misiune în orașul ei. Nicio echipă nu primește o variantă mai ușoară sau mai grea — sarcina, punctajul și termenul sunt identice în toată țara.
              </p>
            </div>
            <div className="stage-card">
              <div className="num">2</div>
              <h3>Finala — Piatra Neamț</h3>
              <p>
                Echipele care trec de etapa orașului merg într-o finală live la Piatra Neamț, unde cele mai bune echipe concurează față în față pentru a decide câștigătorii sezonului.
              </p>
            </div>
          </div>
        </section>
        <section className="section reveal">
          <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center", flexWrap: "wrap", gap: "10px", marginBottom: "16px" }}>
            <h2 style={{ margin: "0" }}>📋 Reguli generale</h2>
            <a className="btn btn-secondary btn-small" href="/rocodefest-rules.pdf" download="">📄 Descarcă regulamentul complet (PDF)</a>
          </div>
          {/* TODO: placeholder — rule codes (G1-G6 below, S1-S6 further down) are a
                      mock taxonomy so the Appeal/Forum "Reference Rules" selectors have
                      something to display. Official codes will come from the regulations
                      via the backend. */}
          <ul className="rule-list">
            <li id="rule-G1">
              <span className="rule-code">G1</span>
              <strong>Aceeași sarcină, în fiecare oraș.</strong>
              {" "}Corectitudinea e pe primul loc — nimeni nu are un avantaj dat de locație.
            </li>
            <li id="rule-G2">
              <span className="rule-code">G2</span>
              <strong>Mărimea echipei și eligibilitatea.</strong>
              {" "}Deschis echipelor de elevi, cu orice nivel de experiență, însoțite de un profesor coordonator sau de un mentor.
            </li>
            <li id="rule-G3">
              <span className="rule-code">G3</span>
              <strong>Structura clubului.</strong>
              {" "}Un club poate înscrie mai multe echipe, fiecare în altă categorie (Robotică, Programare, Design etc.).
            </li>
            <li id="rule-G4">
              <span className="rule-code">G4</span>
              <strong>Conduită.</strong>
              {" "}Regulile obișnuite de fair-play și siguranță se aplică în fiecare etapă. Comportamentul nesportiv duce la descalificare.
            </li>
            <li id="rule-E2">
              <span className="rule-code">E2</span>
              <strong>Proprietate intelectuală.</strong>
              {" "}Tot ce se trimite trebuie să fie munca echipei. Plagiatul sau folosirea neautorizată a codului ori a design-urilor externe duce la eliminare.
            </li>
            <li id="rule-A21">
              <span className="rule-code">A21</span>
              <strong>Contestații.</strong>
              {" "}Fiecare echipă poate depune cel mult 3 contestații pe zi de eveniment, indicând un moment precis din transmisiunea live. După 3 contestații respinse, nu mai sunt acceptate altele.
            </li>
          </ul>
        </section>
        <section className="section reveal">
          <h2>🏆 Regulile probei de sezon</h2>
          <ul className="rule-list">
            <li id="rule-S1">
              <span className="rule-code">S1</span>
              <strong>Proba orașului (etapa 1).</strong>
              {" "}Fiecare echipă îndeplinește aceeași misiune în orașul ei, în același termen. Punctajul este standardizat în toate orașele.
            </li>
            <li id="rule-S2">
              <span className="rule-code">S2</span>
              <strong>Grila de punctare.</strong>
              {" "}Patru criterii: Inovație (1-10), Execuție tehnică (1-10), Prezentare (1-10), Lucru în echipă (1-10). Total maxim: 40 de puncte de la fiecare arbitru.
            </li>
            <li id="rule-S3">
              <span className="rule-code">S3</span>
              <strong>Calificare.</strong>
              {" "}Echipele cu cele mai mari punctaje din fiecare oraș merg în finală. Pragul exact depinde de numărul de participanți.
            </li>
            <li id="rule-S4">
              <span className="rule-code">S4</span>
              <strong>Finala (etapa 2).</strong>
              {" "}Are loc live la Piatra Neamț. Cele mai bune echipe concurează față în față, cu arbitraj pe loc. Rezultatele sunt definitive, cu excepția procedurii de contestație.
            </li>
            <li id="rule-S5">
              <span className="rule-code">S5</span>
              <strong>Premii.</strong>
              {" "}Premii în bani pentru primele locuri, vouchere de la sponsori pentru următoarele clasate și recunoaștere de echipă fondatoare pentru fiecare echipă participantă în sezonul 1.
            </li>
            <li id="rule-S6">
              <span className="rule-code">S6</span>
              <strong>Diplome.</strong>
              {" "}Se generează automat după ce rezultatele devin finale și pot fi descărcate din profilul fiecărui club.
            </li>
          </ul>
        </section>
        <section className="section reveal">
          <h2>Premiile finalei</h2>
          <div className="prize-row">
            <div className="prize"><span>🏆</span><p>Premiu în bani pentru locul 1</p></div>
            <div className="prize"><span>🎟️</span><p>Vouchere de la sponsori pentru cele mai bune echipe</p></div>
            <div className="prize"><span>🥇</span><p>Recunoaștere de echipă fondatoare pentru toți</p></div>
          </div>
        </section>
        <section className="section reveal" style={{ textAlign: "center" }}>
          <h2>Alte pagini ale competiției</h2>
          <div style={{ display: "flex", gap: "12px", justifyContent: "center", flexWrap: "wrap", marginTop: "10px" }}>
            <a className="btn btn-secondary btn-small" href="/submissions">Lucrări</a>
            {" "}
            <a className="btn btn-secondary btn-small" href="/leaderboard">Clasament</a>
            {" "}
            <a className="btn btn-secondary btn-small" href="/appeals">Contestații</a>
            {" "}
            <a className="btn btn-secondary btn-small" href="/certificates">Diplome</a>
          </div>
        </section>
        <HideForClub>
          <div className="final-cta reveal" id="final-cta">
            <h2>Ești gata să accepți provocarea?</h2>
            <p>Înscrierile pentru cluburile fondatoare sunt deschise chiar acum.</p>
            <a className="btn btn-primary" href="/register">Înscrie-ți clubul →</a>
          </div>
        </HideForClub>
        <SiteFooter />
      </div>
      <FabButtons />
      <RevealOnScroll />
      <RulesScript />
    </>
  );
}
