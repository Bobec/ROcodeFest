import type { Metadata } from "next";
import BackButton from "@/components/BackButton";
import SiteFooter from "@/components/SiteFooter";
import SiteHeader from "@/components/SiteHeader";
import "./page.css";
import "@/styles/impuls.css";

export const metadata: Metadata = { title: "Live — IMPULS 2027" };

export default function LivestreamPage() {
  return (
    <>
      <div className="wrap">
        <SiteHeader />
        <BackButton />
        <section className="page-hero">
          <div className="eyebrow">Eveniment live</div>
          <h1>Urmărește IMPULS live</h1>
          <p>
            Finala de la Piatra Neamț va fi transmisă aici. Mai jos vor apărea și transmisiunile din proba orașului.
          </p>
        </section>
        <div className="card" style={{ textAlign: "center" }}>
          <div style={{ background: "var(--ink-bg)", borderRadius: "var(--radius-md)", padding: "80px 20px", color: "#fff", position: "relative", overflow: "hidden" }}>
            <div style={{ fontSize: "48px", marginBottom: "10px" }}>📺</div>
            <h2 style={{ color: "#fff", fontSize: "22px" }}>Transmisiunea începe în ziua evenimentului</h2>
            <p style={{ color: "#999", fontSize: "14px" }}>
              Transmisiunea va apărea aici când începe evenimentul. Canalele oglindă (YouTube/Twitch) vor fi adăugate aici după confirmare.
            </p>
          </div>
          <p style={{ fontSize: "13px", color: "var(--ink-soft)", marginTop: "16px" }}>
            Acest spațiu va fi înlocuit cu transmisiunea reală (YouTube/Twitch) după confirmarea platformei.
          </p>
        </div>
        <div className="section">
          <h2>Transmisiuni din proba orașului</h2>
          <div className="grid-3" id="city-streams">
            <div className="card-light" style={{ textAlign: "center" }}>
              <p style={{ fontWeight: "700" }}>Transmisiunile din orașe vor fi listate aici după confirmarea datelor probei orașului.</p>
            </div>
          </div>
        </div>
        <SiteFooter />
      </div>

    </>
  );
}
