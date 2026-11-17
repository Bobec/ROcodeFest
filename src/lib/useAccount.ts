"use client";
// Who is signed in, asked of the server once per page load and shared by
// every component that needs it (the navigation bar, the CTAs, ...).
import { useEffect, useState } from "react";

export type Account = {
  role: "club" | "member" | "judge" | "partner" | "organizer" | string;
  clubName?: string;
  fullName?: string;
  orgName?: string;
  contactName?: string;
  avatar?: string | null;
};

let request: Promise<Account | null> | null = null;

function fetchAccount(): Promise<Account | null> {
  // With the API down (as on the static deploy) this resolves to null and
  // the page shows its signed-out state -- a smaller failure than a blank one.
  request ??= fetch("/auth/me", { credentials: "same-origin" })
    .then((r) => r.json())
    .then((d) => (d && d.account) || null)
    .catch(() => null);
  return request;
}

/** undefined while the answer is pending, then the account or null. */
export function useAccount(): Account | null | undefined {
  const [account, setAccount] = useState<Account | null | undefined>(undefined);
  useEffect(() => {
    let live = true;
    fetchAccount().then((a) => { if (live) setAccount(a); });
    return () => { live = false; };
  }, []);
  return account;
}
