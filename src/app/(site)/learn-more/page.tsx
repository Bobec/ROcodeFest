import type { Metadata } from "next";
import BackButton from "@/components/BackButton";
import FabButtons from "@/components/FabButtons";
import RevealOnScroll from "@/components/RevealOnScroll";
import SiteFooter from "@/components/SiteFooter";
import SiteHeader from "@/components/SiteHeader";
import HideForClub from "@/components/HideForClub";
import "./page.css";
import "@/styles/impuls.css";

export const metadata: Metadata = { title: "Află mai multe — IMPULS 2027" };

export default function LearnMorePage() {
  return (
    <>
      <div className="wrap">
        <SiteHeader />
        <BackButton />
        <section className="page-hero">
          <div className="eyebrow">Află mai multe</div>
          <h1>Ce este, de fapt, IMPULS?</h1>
          <p>
            Un festival de robotică construit de la zero pentru elevii care vor să construiască, să programeze și să concureze — fără nicio presupunere despre ce știi deja.
          </p>
        </section>
        <section className="section reveal">
          <div className="story-card">
            <h2 style={{ fontSize: "20px" }}>Ideea</h2>
            <p>
              Cele mai multe competiții de robotică există de zeci de ani, cu echipe consacrate, bugete mari și ani de experiență acumulată. Asta intimidează dacă pornești de la zero. IMPULS există ca să fie rampa de lansare: o competiție reală, cu roboți reali și mize reale, gândită anume ca o echipă aflată la început să poată intra fără să se simtă în urmă.
            </p>
          </div>
          <div className="story-card">
            <h2 style={{ fontSize: "20px" }}>Cum funcționează</h2>
            <p>
              IMPULS se desfășoară în două etape. Mai întâi, fiecare echipă primește aceeași misiune, în orașul ei — o probă practică ce testează cum se descurcă robotul în lumea reală, nu doar pe o masă de antrenament. Este pe jumătate competiție, pe jumătate vânătoare de comori, și aici se petrece cea mai mare parte a sezonului.
            </p>
            <p>
              Pentru că fiecare echipă are exact aceeași sarcină, rezultatele se pot compara direct între orașe — fără avantajul terenului propriu, fără variante mai ușoare sau mai grele în funcție de locul în care te afli.
            </p>
            <p>
              Echipele care trec de etapa locală câștigă un loc în finala organizată live la Piatra Neamț, unde cele mai puternice echipe din fiecare oraș se întrec față în față pentru a decide câștigătorii sezonului.
            </p>
          </div>
          <div className="story-card">
            <h2 style={{ fontSize: "20px" }}>Premiile</h2>
            <p>
              Echipele câștigătoare pleacă acasă cu premii în bani și vouchere de la sponsorii noștri — recompense reale pentru un prim sezon construit în întregime de echipele fondatoare.
            </p>
          </div>
        </section>
        <section className="section reveal">
          <div className="eyebrow">În cifre</div>
          <h2>Primul sezon, până acum.</h2>
          <div className="stat-row">
            <div className="stat"><span>120+</span><p>echipe înscrise</p></div>
            <div className="stat"><span>18</span><p>evenimente planificate</p></div>
            <div className="stat"><span>2,000+</span><p>elevi implicați</p></div>
          </div>
        </section>
        <section className="section reveal">
          <div className="eyebrow">Bine de știut</div>
          <h2>Detalii care contează.</h2>
          <div className="grid-2">
            <div className="info-card">
              <h3>Cine poate participa</h3>
              <p>
                Orice echipă de elevi, cu orice nivel de experiență. Sunt binevenite atât echipele de gimnaziu, cât și cele de liceu.
              </p>
            </div>
            <div className="info-card alt">
              <h3>Cât costă</h3>
              <p>Taxa de înscriere este mică, iar echipele care au nevoie pot primi sprijin suplimentar.</p>
            </div>
            <div className="info-card alt">
              <h3>De ce ai nevoie</h3>
              <p>
                O echipă de elevi, un profesor coordonator sau un mentor și curiozitate. De rest se ocupă kiturile de început.
              </p>
            </div>
            <div className="info-card">
              <h3>Unde au loc evenimentele</h3>
              <p>Calificările locale duc la un campionat regional la sfârșitul sezonului.</p>
            </div>
          </div>
        </section>
        <HideForClub>
          <div className="final-cta reveal" id="final-cta">
            <h2>Vrei să vezi dacă e pentru tine?</h2>
            <p>Înscrierile pentru echipele fondatoare sunt deschise chiar acum.</p>
            <a className="btn btn-primary" href="/register">Înscrie-ți clubul →</a>
          </div>
        </HideForClub>
        <SiteFooter />
      </div>
      <FabButtons />
      <RevealOnScroll />
    </>
  );
}
