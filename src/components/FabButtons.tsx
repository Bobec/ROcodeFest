"use client";
// The two floating buttons: share the page, and back to the top.
import { useEffect, useState } from "react";

const SHARE_TEXT = "Descoperă IMPULS — un festival de tehnologie și robotică pentru echipe de elevi și studenți.";

export default function FabButtons({ labels = false }: { labels?: boolean }) {
  const [showTop, setShowTop] = useState(false);
  const [toast, setToast] = useState(false);

  useEffect(() => {
    const onScroll = () => setShowTop(window.scrollY > 400);
    onScroll();
    window.addEventListener("scroll", onScroll, { passive: true });
    return () => window.removeEventListener("scroll", onScroll);
  }, []);

  useEffect(() => {
    if (!toast) return;
    const t = setTimeout(() => setToast(false), 2000);
    return () => clearTimeout(t);
  }, [toast]);

  function share() {
    const url = window.location.href;
    if (navigator.share) {
      navigator.share({ title: "IMPULS", text: SHARE_TEXT, url }).catch(() => {});
    } else if (navigator.clipboard) {
      navigator.clipboard.writeText(url).then(() => setToast(true), () => {});
    }
  }

  return (
    <>
      <div className="fab-stack">
        <button className="fab" id="fab-share" title="Distribuie IMPULS" aria-label="Distribuie" onClick={share}>
          <svg viewBox="0 0 24 24" fill="none" stroke="white" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
            <circle cx="18" cy="5" r="3" /><circle cx="6" cy="12" r="3" /><circle cx="18" cy="19" r="3" />
            <line x1="8.6" y1="10.5" x2="15.4" y2="6.5" /><line x1="8.6" y1="13.5" x2="15.4" y2="17.5" />
          </svg>
          {labels && " Distribuie "}
        </button>
        <button
          className={"fab" + (showTop ? " show" : "")}
          id="fab-top"
          title="Înapoi sus"
          aria-label="Înapoi sus"
          onClick={() => window.scrollTo({ top: 0, behavior: "smooth" })}
        >
          <svg viewBox="0 0 24 24" fill="none" stroke="white" strokeWidth="2.4" strokeLinecap="round" strokeLinejoin="round">
            <line x1="12" y1="19" x2="12" y2="5" /><polyline points="5 12 12 5 19 12" />
          </svg>
          {labels && " Sus "}
        </button>
      </div>
      <div className={"fab-toast" + (toast ? " show" : "")} id="fab-toast">Link copiat!</div>
    </>
  );
}
