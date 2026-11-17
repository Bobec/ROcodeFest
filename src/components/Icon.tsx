// One pixel icon (see lib/icons.ts). Decorative: the text beside it
// says what it means, so it is hidden from screen readers. Sized in em,
// so it follows the font size of whatever it sits in; coloured by
// .px-icon in styles/impuls.css.
import { ICONS, type IconName } from "@/lib/icons";

export default function Icon({ name, className }: { name: IconName; className?: string }) {
  return (
    <svg
      className={"px-icon" + (className ? " " + className : "")}
      viewBox="0 0 24 24"
      fill="currentColor"
      aria-hidden="true"
      focusable="false"
    >
      {ICONS[name].map((d, i) => <path key={i} d={d} />)}
    </svg>
  );
}
