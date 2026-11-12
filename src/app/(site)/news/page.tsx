import type { Metadata } from "next";
import BackButton from "@/components/BackButton";
import FabButtons from "@/components/FabButtons";
import NewsScript from "./PageScript";
import RevealOnScroll from "@/components/RevealOnScroll";
import SiteFooter from "@/components/SiteFooter";
import SiteHeader from "@/components/SiteHeader";
import "./page.css";
import "@/styles/impuls.css";

export const metadata: Metadata = { title: "Noutăți — IMPULS 2027" };

export default function NewsPage() {
  return (
    <>
      <div className="wrap">
        <SiteHeader />
        <BackButton />
        {/* This was a hardcoded empty state: "No news yet", permanently, with
               nothing behind it. Articles are rows now, written by organisers from
               the admin panel. The empty state below is drawn only when the list
               really is empty -- which is a different thing from a page that can
               never say anything else. */}
        <div id="news-list"></div>
        <div className="center-card reveal" id="news-empty" style={{ display: "none" }}>
          <div className="eyebrow">Noutăți</div>
          <h1>Nicio știre încă</h1>
          <p>Aici apar noutățile sezonului, anunțurile și aparițiile în presă.</p>
          <a className="btn btn-primary" href="mailto:hello@rocodefest.example">Scrie-ne →</a>
        </div>
        <SiteFooter />
      </div>
      <FabButtons />
      <RevealOnScroll />
      <NewsScript />
    </>
  );
}
