"use client";
// The navigation bar every page shows. It used to be the same markup
// copied into all 30 HTML files, with five inline scripts behind it: the
// mobile toggle, the sign-in check, the contest-day link, the rules badge
// and the avatar. They are one component now, and each of those is a
// piece of state rather than a script reaching into the page by id.
//
// The ids are kept (nav-login-link, nav-register-link, rules-badge, ...)
// because a few page scripts and the stylesheets still refer to them.
import { useEffect, useRef, useState } from "react";
import { usePathname } from "next/navigation";
import { useAccount, type Account } from "@/lib/useAccount";

// Bump when the rulebook changes: the badge on "Reguli" shows until the
// visitor has opened the rules page since that revision.
const RULES_VERSION = "2026-07-28";
const RULES_SEEN_KEY = "rocodefest_rules_seen";

// TODO: provisional -- contest day is a plain date check until the event
// window comes from the backend. ?preview=1 shows the link outside it.
const EVENT_DATE = new Date("2026-11-14T00:00:00");

// Where the avatar leads, by the role the SERVER reports. An organiser
// needs a branch too (R9): without it they signed in and saw no avatar
// and no way to reach their own panel.
function destinationFor(a: Account): { label: string; href: string } | null {
  switch (a.role) {
    case "club": return { label: a.clubName ?? "", href: "/profile" };
    case "member": return { label: a.fullName ?? "", href: "/member-profile" };
    case "judge": return { label: a.fullName ?? "", href: "/judge-scoring" };
    case "partner": return { label: a.orgName || a.contactName || "", href: "/partner-dashboard" };
    case "organizer": return { label: a.fullName ?? "", href: "/admin" };
    default: return null;
  }
}

function readSeen(): string | null {
  try { return localStorage.getItem(RULES_SEEN_KEY); } catch { return null; }
}
function writeSeen() {
  try { localStorage.setItem(RULES_SEEN_KEY, RULES_VERSION); } catch { /* private mode */ }
}

export default function SiteHeader({ hideLogin = false }: { hideLogin?: boolean }) {
  const pathname = usePathname();
  const [open, setOpen] = useState(false);
  const [scrolled, setScrolled] = useState(false);
  // null until the server answers: "Autentificare" shows meanwhile, and
  // stays if the API is down -- a smaller failure than a blank nav bar.
  const account = useAccount() ?? null;
  const [rulesUnseen, setRulesUnseen] = useState(false);
  const [contestDay, setContestDay] = useState(false);
  const linksRef = useRef<HTMLDivElement>(null);
  const toggleRef = useRef<HTMLButtonElement>(null);

  useEffect(() => {
    const onScroll = () => setScrolled(window.scrollY > 10);
    onScroll();
    window.addEventListener("scroll", onScroll, { passive: true });
    return () => window.removeEventListener("scroll", onScroll);
  }, []);

  useEffect(() => {
    if (pathname === "/rules") { writeSeen(); setRulesUnseen(false); }
    else setRulesUnseen(readSeen() !== RULES_VERSION);
  }, [pathname]);

  useEffect(() => {
    const preview = new URLSearchParams(window.location.search).get("preview") === "1";
    const now = new Date();
    const sameDay = now.getFullYear() === EVENT_DATE.getFullYear()
      && now.getMonth() === EVENT_DATE.getMonth()
      && now.getDate() === EVENT_DATE.getDate();
    setContestDay(sameDay || preview);
  }, []);

  // a click anywhere outside the open mobile menu closes it
  useEffect(() => {
    if (!open) return;
    const onDoc = (e: MouseEvent) => {
      const t = e.target as Node;
      if (linksRef.current?.contains(t) || toggleRef.current?.contains(t)) return;
      setOpen(false);
    };
    document.addEventListener("click", onDoc);
    return () => document.removeEventListener("click", onDoc);
  }, [open]);

  const dest = account ? destinationFor(account) : null;
  const close = () => setOpen(false);

  return (
    <nav className={scrolled ? "scrolled" : undefined}>
      <a className="logo" href="/" aria-label="IMPULS 2027 — acasă">
        <span className="logo-mark"><img src="/assets/impuls-logo.png" alt="" width={50} height={50} /></span>
        <span className="logo-text"><b>IMPULS 2027</b><small>EU CODEZ // PIATRA NEAMȚ</small></span>
      </a>
      <button
        ref={toggleRef}
        className={"nav-toggle" + (open ? " open" : "")}
        id="nav-toggle"
        type="button"
        aria-label="Meniu"
        aria-expanded={open}
        onClick={() => setOpen((o) => !o)}
      >
        <span></span><span></span><span></span>
      </button>
      <div ref={linksRef} className={"nav-links" + (open ? " open" : "")} onClick={(e) => { if ((e.target as HTMLElement).closest("a")) close(); }}>
        <a href="/learn-more">Despre</a>
        <span className="nav-rules-wrap">
          <a href="/rules">Reguli</a>
          <span className={"rules-badge" + (rulesUnseen ? " show" : "")} id="rules-badge"></span>
        </span>
        <a href="/events">Evenimente</a>
        <a href="/contest-day" id="nav-contest-day-link" style={contestDay ? undefined : { display: "none" }}>Ziua concursului</a>
        <a href="/forum">Forum</a>
        {!hideLogin && !account && <a href="/login" id="nav-login-link">Autentificare</a>}
        {dest ? (
          <a
            href={dest.href}
            id="nav-register-link"
            className={"profile-avatar" + (account!.role !== "club" ? " member-avatar" : "")}
            title={dest.label}
            style={account!.avatar ? { backgroundImage: `url(${account!.avatar})` } : undefined}
          >
            {account!.avatar ? "" : (dest.label || "?").trim().charAt(0).toUpperCase()}
          </a>
        ) : (
          !account && <a href="/register" id="nav-register-link">Înregistrare</a>
        )}
        <a href="/join-as" className="join-cta-link">// Participă</a>
      </div>
    </nav>
  );
}
