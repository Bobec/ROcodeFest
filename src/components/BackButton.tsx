"use client";
// Prefers the page that actually linked here (deterministic, and it does
// not bounce in a back/forward loop); then browser history; then home.
export default function BackButton() {
  function goBack() {
    const ref = document.referrer;
    if (ref && ref.startsWith(window.location.origin) && ref !== window.location.href) {
      window.location.href = ref;
    } else if (window.history.length > 1) {
      window.history.back();
    } else {
      window.location.href = "/";
    }
  }
  return (
    <button type="button" className="back-nav-btn" onClick={goBack} aria-label="Înapoi">
      &larr; Înapoi
    </button>
  );
}
