import type { Metadata } from "next";
import BackButton from "@/components/BackButton";
import FabButtons from "@/components/FabButtons";
import ForumScript from "./PageScript";
import SiteFooter from "@/components/SiteFooter";
import SiteHeader from "@/components/SiteHeader";
import "./page.css";
import "@/styles/impuls.css";

export const metadata: Metadata = { title: "Forum — IMPULS 2027" };

export default function ForumPage() {
  return (
    <>
      <div className="wrap">
        <SiteHeader />
        <BackButton />
        <section className="page-hero">
          <div className="eyebrow">Comunitate</div>
          <h1>Forumul IMPULS</h1>
          <p>Discută, pune întrebări și schimbă idei cu alte echipe și cu organizatorii.</p>
        </section>
        <div className="announcements-panel" id="announcements-panel">
          <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center", marginBottom: "10px", gap: "10px", flexWrap: "wrap" }}>
            <h2 style={{ margin: "0" }}>📌 Anunțuri</h2>
            <button className="btn btn-secondary btn-small" id="new-announcement-toggle">+ Anunț nou</button>
          </div>
          <div id="announcement-form" style={{ display: "none", marginBottom: "14px" }}>
            <div className="field" style={{ margin: "0 0 8px" }}><input id="new-ann-title" placeholder="Titlul anunțului" /></div>
            <div className="field" style={{ margin: "0" }}><textarea id="new-ann-body" rows={2} placeholder="Detaliile anunțului" /></div>
            <button className="btn btn-primary btn-small" id="post-announcement-btn" style={{ marginTop: "8px" }}>Publică anunțul</button>
          </div>
          <div id="announcements-list"></div>
        </div>
        <div className="forum-cats">
          <div className="cat-parent">📁 General</div>
          <div className="tab-row cat-sub-row" id="forum-tabs">
            <button className="tab-btn active" data-cat="general">Toate</button>
            {" "}
            <button className="tab-btn" data-cat="robotics">Robotică</button>
            {" "}
            <button className="tab-btn" data-cat="programming">Programare</button>
            {" "}
            <button className="tab-btn" data-cat="design">Design</button>
          </div>
        </div>
        <div className="card" id="new-thread-card">
          <p className="composer-session-line" id="thread-session-line"></p>
          <div className="grid-2" style={{ gap: "10px" }}>
            <div className="field" style={{ margin: "0" }}><input id="new-thread-title" placeholder="Titlul subiectului" /></div>
            <div style={{ display: "flex", gap: "8px" }}>
              {/* A "Your name" box for signed-out visitors stood here.
                           forum_posts.author_account_id is NOT NULL, so a guest post
                           could never have become a row; the composer now says to sign
                           in instead. */}
              <button className="btn btn-primary btn-small" id="post-thread-btn" style={{ flex: "1" }}>Publică</button>
            </div>
          </div>
          <div className="field" style={{ marginTop: "10px", marginBottom: "0" }}><textarea id="new-thread-body" rows={2} placeholder="La ce te gândești?" /></div>
          {/* An "Attach image / video / file" row stood here. It read no file
                   content and uploaded nothing -- its own chips said "mock
                   attachment — no upload yet" -- so nothing is lost by removing it.
                   forum_attachments records a file's name, type, size and a
                   storage_key pointing at a file store, and this project has no file
                   store. Offering the button without one is offering something that
                   cannot happen. */}
          <div className="file-row">
            {/* TODO: placeholder — mock button only, not wired to the regulations yet */}
            <button type="button" className="rules-ref-btn" title="Doar machetă — va deschide regulamentul oficial după conectarea la server">📖 Vezi regulile</button>
          </div>
        </div>
        <div id="threads-list"></div>
        <SiteFooter />
      </div>
      <FabButtons labels />
      <ForumScript />
    </>
  );
}
