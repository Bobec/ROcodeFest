const LINKS: [href: string, label: string][] = [
  ["/news", "Noutăți"],
  ["/resources", "Resurse"],
  ["/founding-teams", "Echipe"],
  ["/organizations", "Cluburi"],
  ["/leaderboard", "Clasament"],
  ["/forum", "Forum"],
  ["/livestream", "Live"],
  ["/contact", "Contact"],
];

export default function SiteFooter() {
  return (
    <footer>
      <div className="footer-nav">
        {LINKS.map(([href, label]) => (
          <a key={href} href={href}>{label}</a>
        ))}
      </div>
      IMPULS 2027 // EU CODEZ // PIATRA NEAMȚ
    </footer>
  );
}
