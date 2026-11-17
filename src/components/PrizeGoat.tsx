// The goat from the folk motif (bg-capra-motiv.png), extruded into a
// solid and turning on its vertical axis. There is no 3D model: the
// motif is used as a mask on LAYERS thin slices stacked 1px apart in
// depth, so seen edge-on the slices read as the goat's thickness. The
// front and back slices are the bright faces, the ones between them the
// darker sides. The stylesheet (rules/page.css, .goat3d) does the rest.
import type { CSSProperties } from "react";

const LAYERS = 16;

export default function PrizeGoat() {
  return (
    <div className="goat3d" role="img" aria-label="Capra IMPULS">
      <div className="goat3d-spin">
        {Array.from({ length: LAYERS }, (_, i) => (
          <div
            key={i}
            className="goat3d-layer"
            style={{ "--z": `${i - (LAYERS - 1) / 2}px`, "--d": i / (LAYERS - 1) } as CSSProperties}
          />
        ))}
      </div>
    </div>
  );
}
