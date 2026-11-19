// Baut links-browser.pdf: Links an Stellen im selben Dokument, wie Chrome sie in ein PDF schreibt (benannte Ziele).
// Aufruf: node make_links_browser.js [Ausgabe.pdf]
const { chromium } = require('playwright');

const filler = (n) => Array.from({ length: n }, (_, i) =>
  `<p class="f">Zeile ${i + 1}: Füllschrift, damit man die Lage der Ziele sieht.</p>`).join('');

const html = `<!doctype html><html lang="de"><meta charset="utf-8"><style>
  body { font: 15px Helvetica, Arial, sans-serif; margin: 0; }
  .page { page-break-after: always; }
  a { color: #00c; }
  .f { color: #777; margin: 6px 0; }
  .ziel { color: #c00; border-top: 2px solid #c00; padding-top: 4px; margin: 18px 0 6px; }
</style>
<div class="page"><h1>Links aus dem Browser</h1>
  <p><a href="#ziel-a">0: Ziel A (Seite 2, Mitte)</a></p>
  <p><a href="#ziel-b">1: Ziel B (Seite 3, oben)</a></p>
  <p><a href="https://example.com/">2: example.com (Internet, Webseite)</a></p>
  ${filler(20)}</div>
<div class="page"><h2>Seite 2</h2>${filler(14)}<h3 class="ziel" id="ziel-a">Ziel A</h3>${filler(12)}</div>
<div class="page"><h3 class="ziel" id="ziel-b">Ziel B</h3>${filler(20)}
  <p><a href="#top-1">Zurück zum Anfang</a></p></div>
</html>`.replace('<div class="page"><h1>', '<div class="page" id="top-1"><h1>');

(async () => {
  const browser = await chromium.launch();
  const page = await browser.newPage();
  await page.setContent(html);
  const out = process.argv[2] || 'links-browser.pdf';
  await page.pdf({ path: out, format: 'A4', margin: { top: '20mm', bottom: '20mm', left: '20mm', right: '20mm' } });
  await browser.close();
  console.log(out);
})();
