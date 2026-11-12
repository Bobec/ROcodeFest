import type { Metadata } from "next";
import BackButton from "@/components/BackButton";
import FabButtons from "@/components/FabButtons";
import IndexScript from "./PageScript";
import RevealOnScroll from "@/components/RevealOnScroll";
import SiteFooter from "@/components/SiteFooter";
import SiteHeader from "@/components/SiteHeader";
import HideForClub from "@/components/HideForClub";
import "./page.css";
import "@/styles/impuls.css";

export const metadata: Metadata = { title: "IMPULS 2027 — Eu Codez // Piatra Neamț" };

export default function IndexPage() {
  return (
    <>
      {/* the waves from the goat's horns: a fixed layer of their own, drawn
          between the goat (body::before) and the hill (body::after) by DOM
          order -- see .capra-unde in impuls.css */}
      <div className="capra-unde" aria-hidden="true">
        <i className="unda st"></i><i className="unda st unda-2"></i><i className="unda dr"></i><i className="unda dr unda-2"></i>
      </div>
      <div className="wrap">
        <SiteHeader />
        <BackButton />
        <section className="hero">
          <h1>Semnal detectat</h1>
          <p className="signal">{">> Activează pentru viitor"}</p>
          <p className="signal">{">> Probleme reale. Minți tinere. Tehnologie în acțiune"}</p>
          <p className="lead">
            {"// Un festival de tehnologie, robotică și inovație în care elevii și studenții devin echipe de intervenție, pregătite să transforme provocările reale ale industriei în soluții."}
          </p>
          <a className="mission-btn" href="#descopera">{"> Descoperă festivalul <"}</a>
          <div className="audience-row">
            <a className="btn btn-secondary" href="/join-as">{"// Pentru elevi"}</a>
            {" "}
            <a className="btn btn-secondary" href="/partner">{"// Pentru industrie"}</a>
          </div>
          <div className="countdown-label">Timp rămas până la misiunea finală</div>
          <div className="countdown" id="countdown">
            <div className="unit"><span id="cd-days">--</span><small>zile</small></div>
            <div className="unit"><span id="cd-hours">--</span><small>ore</small></div>
            <div className="unit"><span id="cd-mins">--</span><small>min</small></div>
            <div className="unit"><span id="cd-secs">--</span><small>sec</small></div>
          </div>
        </section>
        <section className="section brief reveal" id="descopera">
          <h2>Descoperă festivalul</h2>
          <div className="eyebrow">Nu venim doar să concurăm. Venim să rezolvăm.</div>
          <p>
            {"// Ideile au nevoie de provocări reale. Iar provocările reale au nevoie de oameni care știu să gândească diferit."}
          </p>
          <p>
            {"// IMPULS aduce împreună elevi, studenți și companii într-un spațiu în care tehnologia devine instrument de rezolvare a problemelor."}
          </p>
          <p>
            {"// Companiile propun provocări. Echipele le analizează, experimentează și construiesc soluții folosind robotica, programarea și tehnologiile emergente."}
          </p>
          <p>
            {"// Un punct de întâlnire între educație și industrie. O comunitate activată prin inovație."}
          </p>
          <div className="cta-row"><a className="btn btn-primary" href="/join-as">{"> Participă <"}</a></div>
          <p>
            {"// Ai o problemă care merită rezolvată? Adu-o în fața unei noi generații de oameni pasionați de tehnologie. Devino partener de misiune și contribuie la dezvoltarea următoarelor soluții."}
          </p>
          <div className="cta-row"><a className="btn btn-primary" href="/partner">{"> Devino partener <"}</a></div>
        </section>
        <section className="section reveal" id="cum-participi">
          <h2>Cum participi</h2>
          <div className="eyebrow">De la provocare la soluție.</div>
          <div className="steps">
            <div className="step">
              <h3><span>01</span> — Activare</h3>
              <p>Înscrie-te, formează-ți echipa de intervenție și pregătește-te pentru prima misiune.</p>
            </div>
            <div className="step">
              <h3><span>02</span> — Selecție</h3>
              <p>
                Îndeplinește misiunea inițială și demonstrează că echipa ta este pregătită pentru intervenție.
              </p>
            </div>
            <div className="step">
              <h3><span>03</span> — Intervenție</h3>
              <p>
                Primește o provocare reală din industrie. Analizează problema, lucrează în sprinturi și dezvoltă o soluție.
              </p>
            </div>
            <div className="step">
              <h3><span>04</span> — Misiunea finală</h3>
              <p>
                Cele mai bune echipe ajung la Rubik Hub, unde își prezintă soluțiile în fața juriului și concurează pentru premii.
              </p>
            </div>
          </div>
        </section>
        <section className="section reveal">
          <h2>Nu ești singur</h2>
          <div className="eyebrow">Sprijin din prima zi.</div>
          <div className="support-grid">
            <div className="support-item"><div className="emoji-circle">🧰</div><p>Kituri de început</p></div>
            <div className="support-item"><div className="emoji-circle">🧑‍🏫</div><p>Rețea de mentori</p></div>
            <div className="support-item"><div className="emoji-circle">📘</div><p>Ghiduri pentru începători</p></div>
            <div className="support-item"><div className="emoji-circle">💬</div><p>Chat de comunitate</p></div>
          </div>
        </section>
        <section className="section reveal">
          <h2>Cine sunt organizatorii</h2>
          <div className="eyebrow">Cine e în spatele festivalului.</div>
          <div className="organizer-card">
            <div className="organizer-avatar">I</div>
            <div>
              <h3 style={{ fontSize: "22px" }}>Am pornit IMPULS pentru că orice echipă bună are nevoie de o primă șansă.</h3>
              <p>
                Suntem o echipă mică de ingineri și profesori care și-au dorit un eveniment în care începătorii sunt la fel de bineveniți ca veteranii. Este prima ediție — și o construim împreună cu voi, nu doar pentru voi.
              </p>
            </div>
          </div>
        </section>
        <section className="section reveal">
          <h2>Întrebări frecvente</h2>
          <div className="eyebrow">Încă nu te-ai hotărât?</div>
          <div className="faq-list">
            <details className="faq-item">
              <summary>Nu am mai concurat niciodată — ne putem înscrie?<i className="chev">+</i></summary>
              <p>
                Da. Cele mai multe echipe aflate la prima participare nu au nicio experiență. Exact pentru ele este gândit evenimentul.
              </p>
            </details>
            <details className="faq-item">
              <summary>Ce se întâmplă dacă nu terminăm robotul la timp?<i className="chev">+</i></summary>
              <p>
                Proiectele neterminate sunt binevenite. Contează mai mult să participi și să înveți decât să ai un robot perfect.
              </p>
            </details>
            <details className="faq-item">
              <summary>Este o competiție reală, care va continua?<i className="chev">+</i></summary>
              <p>
                Da — este prima noastră ediție și ne-am angajat să o organizăm în fiecare an de acum înainte.
              </p>
            </details>
            <details className="faq-item">
              <summary>Cât costă înscrierea?<i className="chev">+</i></summary>
              <p>Taxa de înscriere este mică, iar echipele care au nevoie pot primi sprijin.</p>
            </details>
          </div>
        </section>
        <HideForClub>
          <div className="final-cta reveal" id="final-cta">
            <h2>Misiune disponibilă</h2>
            <p>Fără robot, fără experiență — nicio problemă. Adu doar o echipă.</p>
            <div className="cta-row">
              <a className="btn btn-primary" href="/register">{"> Înscrie-ți clubul <"}</a>
              {" "}
              <a className="btn btn-secondary" href="/register">{"// Vorbește cu un mentor"}</a>
            </div>
          </div>
        </HideForClub>
        <SiteFooter />
      </div>
      <FabButtons labels />
      <RevealOnScroll />
      <IndexScript />
    </>
  );
}
