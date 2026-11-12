import type { Metadata, Viewport } from "next";
import type { ReactNode } from "react";
import Document from "@/components/Document";

export const metadata: Metadata = { title: "IMPULS 2027 — Eu Codez // Piatra Neamț" };
export const viewport: Viewport = { width: "device-width", initialScale: 1 };

export default function HomeLayout({ children }: { children: ReactNode }) {
  return <Document bodyClass="home">{children}</Document>;
}
