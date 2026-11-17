// Forum is not repeated here: it is already in the navigation bar.
// Teams and clubs are one page (/founding-teams), so one link.
const LINKS: [href: string, label: string][] = [
  ["/news", "Noutăți"],
  ["/resources", "Resurse"],
  ["/founding-teams", "Echipe și cluburi"],
  ["/leaderboard", "Clasament"],
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
