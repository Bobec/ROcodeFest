import type { Metadata } from "next";
import BackButton from "@/components/BackButton";
import FabButtons from "@/components/FabButtons";
import RevealOnScroll from "@/components/RevealOnScroll";
import SiteFooter from "@/components/SiteFooter";
import SiteHeader from "@/components/SiteHeader";
import "./page.css";
import "@/styles/impuls.css";

export const metadata: Metadata = { title: "Resurse — IMPULS 2027" };

export default function ResourcesPage() {
  return (
    <>
      <div className="wrap">
        <SiteHeader />
        <BackButton />
        <section className="page-hero">
          <div className="eyebrow">Resurse</div>
          <h1>Tot ce îi trebuie unei echipe la început</h1>
          <p>Ghiduri, unelte și sprijin ca să-ți duci robotul de la idee până la proba orașului.</p>
        </section>
        <section className="section reveal">
          <div className="resource-grid">
            <div className="resource-card">
              <div className="emoji-circle">🧰</div>
              <div>
                <h3>Ghidul kitului de început</h3>
                <p>Ce găsești în kit și cum începi prima construcție.</p>
              </div>
            </div>
            <div className="resource-card">
              <div className="emoji-circle">💻</div>
              <div>
                <h3>Bazele programării</h3>
                <p>Ghiduri pentru începători despre programarea robotului, fără experiență anterioară.</p>
              </div>
            </div>
            <div className="resource-card">
              <div className="emoji-circle">📘</div>
              <div>
                <h3>Manualul jocului</h3>
                <p>Regulamentul complet pentru proba orașului și finala de la Piatra Neamț.</p>
              </div>
            </div>
            <div className="resource-card">
              <div className="emoji-circle">🧑‍🏫</div>
              <div>
                <h3>Rețeaua de mentori</h3>
                <p>Primești un mentor care te ajută să rezolvi problemele apărute pe parcurs.</p>
              </div>
            </div>
            <div className="resource-card">
              <div className="emoji-circle">💬</div>
              <div>
                <h3>Chat de comunitate</h3>
                <p>Pune întrebări și ia legătura în timp real cu alte echipe fondatoare.</p>
              </div>
            </div>
            <div className="resource-card">
              <div className="emoji-circle">❓</div>
              <div>
                <h3>Întrebări frecvente</h3>
                <p>Răspunsuri la cele mai frecvente întrebări ale echipelor aflate la început.</p>
              </div>
            </div>
          </div>
        </section>
        <div className="final-cta reveal">
          <h2>Ai o întrebare la care nu am răspuns?</h2>
          <p>Scrie-ne și te ajutăm să mergi mai departe.</p>
          <a className="btn btn-primary" href="/contact">Contactează-ne →</a>
        </div>
        <SiteFooter />
      </div>
      <FabButtons />
      <RevealOnScroll />
    </>
  );
}
