"use client";
// A club that is already registered does not need to be asked to register.
// The old pages tried this with a variable (`session2`) that no longer
// existed, so the line threw and the call to action always showed.
import type { ReactNode } from "react";
import { useAccount } from "@/lib/useAccount";

export default function HideForClub({ children }: { children: ReactNode }) {
  const account = useAccount();
  if (account && account.role === "club") return null;
  return <>{children}</>;
}
