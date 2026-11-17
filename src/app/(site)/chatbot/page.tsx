import type { Metadata } from "next";
import BackButton from "@/components/BackButton";
import ChatbotScript from "./PageScript";
import SiteFooter from "@/components/SiteFooter";
import SiteHeader from "@/components/SiteHeader";
import "./page.css";
import "@/styles/impuls.css";

export const metadata: Metadata = { title: "Ajutor — IMPULS 2027" };

export default function ChatbotPage() {
  return (
    <>
      <div className="wrap">
        <SiteHeader />
        <BackButton />
        <section className="page-hero">
          <div className="eyebrow">Ajutor</div>
          <h1>Asistentul IMPULS</h1>
          <p>Întreabă-mă orice despre competiție, înscriere, reguli sau evenimente.</p>
        </section>
        <div className="card" style={{ maxWidth: "600px", margin: "0 auto" }}>
          <div id="chat-messages" style={{ maxHeight: "400px", overflowY: "auto", marginBottom: "16px" }}>
            <div className="bot-msg">
              Salut! Pot răspunde la întrebări despre IMPULS. Întreabă-mă despre înscriere, reguli, proba orașului, finală, premii sau orice altceva.
            </div>
          </div>
          <div style={{ display: "flex", gap: "8px" }}>
            <input type="text" id="chat-input" placeholder="Scrie întrebarea..." style={{ flex: "1" }} />
            {" "}
            <button className="btn btn-primary btn-small" id="chat-send">Trimite</button>
          </div>
        </div>
        <SiteFooter />
      </div>
      <ChatbotScript />
    </>
  );
}
