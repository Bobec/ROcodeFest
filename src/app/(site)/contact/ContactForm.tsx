"use client";
// The message form on /contact. It posts to /api/contact (api/routes/
// contact.js), which keeps the message for the organisers to read in
// /admin. `website` is a honeypot: hidden from people, filled in by most
// bots, and a message that has it is quietly dropped by the API.
import { useState, type FormEvent } from "react";

type State = { kind: "idle" } | { kind: "sending" } | { kind: "sent" } | { kind: "error"; message: string };

export default function ContactForm() {
  const [state, setState] = useState<State>({ kind: "idle" });

  async function onSubmit(e: FormEvent<HTMLFormElement>) {
    e.preventDefault();
    const form = e.currentTarget;
    const data = Object.fromEntries(new FormData(form)) as Record<string, string>;
    setState({ kind: "sending" });
    try {
      const r = await fetch("/api/contact", {
        method: "POST",
        credentials: "same-origin",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(data),
      });
      const body = await r.json().catch(() => ({}));
      if (!r.ok) {
        setState({ kind: "error", message: body.error || "Mesajul nu a putut fi trimis. Încearcă din nou." });
        return;
      }
      form.reset();
      setState({ kind: "sent" });
    } catch {
      setState({ kind: "error", message: "Nu ne-am putut conecta. Verifică internetul și încearcă din nou." });
    }
  }

  if (state.kind === "sent") {
    return (
      <div className="contact-form contact-sent" role="status">
        <h3>Mesaj trimis ✓</h3>
        <p>Mulțumim! Îți răspundem pe email cât de curând.</p>
        <button type="button" className="btn btn-secondary btn-small" onClick={() => setState({ kind: "idle" })}>
          Trimite alt mesaj
        </button>
      </div>
    );
  }

  const sending = state.kind === "sending";
  return (
    <form className="contact-form" onSubmit={onSubmit} noValidate={false}>
      <div className="contact-form-row">
        <label>
          <span>Nume</span>
          <input name="name" type="text" required maxLength={120} autoComplete="name" />
        </label>
        <label>
          <span>Email</span>
          <input name="email" type="email" required maxLength={254} autoComplete="email" />
        </label>
      </div>
      <label>
        <span>Mesaj</span>
        <textarea name="message" required maxLength={5000} rows={6} />
      </label>
      <label className="contact-hp" aria-hidden="true">
        <span>Site web</span>
        <input name="website" type="text" tabIndex={-1} autoComplete="off" />
      </label>
      {state.kind === "error" && <p className="contact-error" role="alert">{state.message}</p>}
      <button className="btn btn-primary" type="submit" disabled={sending}>
        {sending ? "Se trimite…" : "Trimite mesajul →"}
      </button>
    </form>
  );
}
