import type { ReactNode } from "react";

// The <html> and <body> every page shares. There are two root layouts --
// (home) and (site) -- only because the home page's <body> carries the
// "home" class that impuls.css hangs the background artwork on, and a
// root layout is the one place that owns <body>.
export default function Document({ bodyClass, children }: { bodyClass?: string; children: ReactNode }) {
  return (
    <html lang="ro">
      <body className={bodyClass}>{children}</body>
    </html>
  );
}
