// Baut Notizbuch/Antwort.html: die Seite, in der die App Claudes Antworten zeigt (Markdown mit Formeln, ohne Netz).
// Alles steckt in dieser einen Datei: KaTeX samt Schriften (nur woff2), markdown-it und markdown-it-texmath, alle unter
// MIT-Lizenz (die Hinweise stehen oben in der Datei). Nur nötig, um die Bibliotheken zu erneuern:
//
//   mkdir /tmp/antwort && cd /tmp/antwort
//   npm pack katex@0.19.1 markdown-it@15.0.3 markdown-it-texmath@1.0.0
//   for f in *.tgz; do mkdir "${f%.tgz}"; tar xzf "$f" -C "${f%.tgz}"; done
//   node native/Notizbuch/antwort-html.mjs /tmp/antwort   (im Ordner des Repos)
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const dir = process.argv[2];
if (!dir) {
  console.error("Ordner mit den ausgepackten Paketen fehlt (siehe oben)");
  process.exit(1);
}

/// Ordner eines ausgepackten Pakets: <name>-<Version>/package
function pkg(name) {
  const found = fs
    .readdirSync(dir)
    .find((f) => f.startsWith(name + "-") && /^\d/.test(f.slice(name.length + 1)) && fs.statSync(path.join(dir, f)).isDirectory());
  if (!found) throw new Error(`${name} fehlt in ${dir}`);
  return { dir: path.join(dir, found, "package"), version: found.slice(name.length + 1) };
}

const katex = pkg("katex"), markdownIt = pkg("markdown-it"), texmath = pkg("markdown-it-texmath");
const read = (p) => fs.readFileSync(p, "utf8");

// Schriften als data-URIs (nur woff2: WebKit kann es, die anderen Formate wären nur Ballast)
const fonts = path.join(katex.dir, "dist", "fonts");
const css = read(path.join(katex.dir, "dist", "katex.min.css")).replace(
  /src:url\(fonts\/([^)]+?)\.woff2\) format\("woff2"\)(?:,url\([^)]*\) format\("[^"]*"\))*/g,
  (_, name) => {
    const data = fs.readFileSync(path.join(fonts, name + ".woff2")).toString("base64");
    return `src:url(data:font/woff2;base64,${data}) format("woff2")`;
  },
);
if (/url\(fonts\//.test(css)) throw new Error("Nicht alle Schriften eingebettet");

/// Skript sicher in <script> einbetten
const script = (code) => code.replace(/<\/(script)/gi, "<\\/$1");

const license = (p) => read(p).trim().replace(/--/g, "- -");
const licenses = [
  [`KaTeX ${katex.version}`, path.join(katex.dir, "LICENSE")],
  [`markdown-it ${markdownIt.version}`, path.join(markdownIt.dir, "LICENSE")],
  [`markdown-it-texmath ${texmath.version}`, path.join(texmath.dir, "license.txt")],
]
  .map(([name, file]) => `${name}\n\n${license(file)}`)
  .join("\n\n----------------------------------------\n\n");

const page = `<!doctype html>
<html lang="de">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<!--
Antwort.html: Claudes Antworten in der Notizbuch-App (BetterNotes). Gebaut mit native/Notizbuch/antwort-html.mjs.
Enthält diese Bibliotheken unter MIT-Lizenz:

${licenses}
-->
<style>${css}</style>
<style>
:root { color-scheme: light; }
body { font: -apple-system-body; margin: 0; padding: 10px 16px 32px; color: #1c1c1e; background: transparent;
  -webkit-text-size-adjust: 100%; overflow-wrap: break-word; line-height: 1.4; }
p, ul, ol, pre, blockquote, table { margin: 0 0 .7em; }
h1, h2, h3, h4, h5, h6 { font-size: 1.05em; margin: 1em 0 .4em; }
ul, ol { padding-left: 1.4em; }
li { margin: .15em 0; }
code { font: .9em ui-monospace, Menlo, monospace; background: #f2f2f7; padding: .05em .3em; border-radius: 4px; }
pre { background: #f2f2f7; padding: .6em .8em; border-radius: 8px; overflow-x: auto; }
pre code { background: none; padding: 0; }
blockquote { border-left: 3px solid #d1d1d6; padding-left: .8em; color: #3a3a3c; margin-left: 0; }
table { border-collapse: collapse; display: block; overflow-x: auto; }
td, th { border: 1px solid #d1d1d6; padding: .25em .5em; }
hr { border: none; border-top: 1px solid #d1d1d6; }
a { color: #007aff; text-decoration: none; overflow-wrap: anywhere; }
.host { color: #8e8e93; font-size: .85em; }
.katex { font-size: 1.05em; }
/* Lange Formeln im Text scrollen für sich, statt die ganze Seite zu verbreitern */
eq { display: inline-block; max-width: 100%; overflow-x: auto; overflow-y: hidden; vertical-align: middle; }
section { margin: .4em 0 .8em; }
eqn { display: block; overflow-x: auto; overflow-y: hidden; padding: .1em 0; }
eqn .katex-display { margin: 0; }
section.eqno { display: flex; align-items: center; }
section.eqno > eqn { flex: 1; }
section.eqno > span { margin-left: 1em; }
</style>
</head>
<body>
<div id="out"></div>
<script>${script(read(path.join(katex.dir, "dist", "katex.min.js")))}</script>
<script>${script(read(path.join(markdownIt.dir, "dist", "browser", "markdown-it.umd.min.js")))}</script>
<script>${script(read(path.join(texmath.dir, "texmath.js")))}</script>
<script>
// Kein HTML aus der Antwort (wird als Text gezeigt), keine Bilder (nichts lädt aus dem Netz), KaTeX ohne \\href und
// Co. (trust: false). Links öffnen erst beim Antippen, im Browser (die App fängt sie ab)
const macros = { "\\\\R": "\\\\mathbb{R}", "\\\\N": "\\\\mathbb{N}", "\\\\Z": "\\\\mathbb{Z}", "\\\\Q": "\\\\mathbb{Q}",
  "\\\\C": "\\\\mathbb{C}" };
const katexOptions = { throwOnError: false, strict: "ignore", output: "htmlAndMathml", trust: false, macros };
// Abgesetzte Formeln ($$…$$, \\[…\\]) als eigener Block nur, wenn danach nichts mehr in der Zeile steht. Sonst ginge
// der Rest der Zeile verloren; so setzt sie die Regel im Absatz ab, und der Text danach bleibt
for (const set of ["dollars", "brackets"]) {
  for (const rule of texmath.rules[set].block) {
    const post = rule.post;
    rule.post = (str, outer, end) => (!post || post(str, outer, end)) && /^[ \\t]*(?:\\r?\\n|$)/.test(str.slice(end + 1));
  }
}
// \\[…\\] auch mitten im Absatz, abgesetzt wie $$…$$ (Claude schreibt sie oft direkt unter eine Textzeile)
texmath.rules.brackets.inline.push({ name: "math_inline_bracket_display", rex: /\\\\\\[([\\s\\S]+?)\\\\\\]/gy,
  tmpl: "<section><eqn>$1</eqn></section>", tag: "\\\\[", displayMode: true });
// Keine Bilder und Verweise ([x]: …) aus der Antwort: nichts lädt aus dem Netz, und „[0,1]: wachsend“ bleibt Text.
// Links (etwa die Quellen einer Websuche) nur mit http(s), auch als nackte Adresse; „x.de“ ohne https:// bleibt Text
const md = window.markdownit({ html: false, linkify: true, typographer: false })
  .disable(["image", "reference"])
  .use(texmath, { engine: katex, delimiters: ["dollars", "brackets"], katexOptions });
md.validateLink = (url) => /^https?:\\/\\//i.test(url);
md.linkify.set({ fuzzyLink: false, fuzzyEmail: false, fuzzyIP: false });
// Ein Doppelpunkt am Ende einer nackten Adresse gehört nicht dazu („Laut https://…/Produktregel: …“, „**https://…**:“)
const normalizeMatch = md.linkify.normalize.bind(md.linkify);
md.linkify.normalize = (m) => {
  normalizeMatch(m);
  const t = /[:*]*:[:*]*$/.exec(m.url);
  if (t) { const n = t[0].length; m.url = m.url.slice(0, -n); m.text = m.text.slice(0, -n); m.lastIndex -= n; }
};
// Nackte Adressen nimmt markdown-it roh aus dem Text, samt Markdown-Escapes (\\_ \\*): die vor Ziel und Text entfernen
const unesc = (u) => u.replace(/\\\\([!-\\/:-@\\[-\`{-~])/g, "$1");
const normalizeLink = md.normalizeLink.bind(md), normalizeLinkText = md.normalizeLinkText.bind(md);
md.normalizeLink = (u) => normalizeLink(unesc(u));
md.normalizeLinkText = (u) => normalizeLinkText(unesc(u));
// Das HTML von KaTeX als Funktion einsetzen: als Ersatztext würde replace $&, $$ … darin umdeuten
const esc = (t) => String(t).replace(/[&<>"']/g, (c) => "&#" + c.charCodeAt(0) + ";");
// Wohin ein Link mit eigenem Text führt, steht klein dahinter: Der Text könnte etwas anderes behaupten oder
// unsichtbar sein. Nackte Adressen zeigen sich selbst
md.renderer.rules.link_close = (tokens, i, options, env, self) => {
  let j = i;
  while (j > 0 && tokens[j].type !== "link_open") j--;
  const open = tokens[j];
  let host = "";
  try { host = new URL(open.attrGet("href")).hostname.replace(/^www\\./, ""); } catch (e) {}
  const bare = open.markup === "linkify" || open.markup === "autolink";
  return self.renderToken(tokens, i, options) + (host && !bare ? '<span class="host"> (' + esc(host) + ")</span>" : "");
};
for (const set of ["dollars", "brackets"]) {
  for (const rule of texmath.rules[set].inline) {
    md.renderer.rules[rule.name] = (tokens, i) =>
      rule.tmpl.replace("$1", () => texmath.render(tokens[i].content, !!rule.displayMode, katexOptions));
  }
  for (const rule of texmath.rules[set].block) {
    md.renderer.rules[rule.name] = (tokens, i) => rule.tmpl.replace(/\\$([12])/g, (_, n) =>
      n === "1" ? texmath.render(tokens[i].content, true, katexOptions) : esc(tokens[i].info));
  }
}
// Steuerzeichen für die Schreibrichtung weg: Sie könnten Text (etwa eine Adresse) anders zeigen, als er ist
const clean = (text) => String(text || "").replace(/[\\u202A-\\u202E\\u2066-\\u2069]/g, "");
function render(text) {
  const out = document.getElementById("out");
  try {
    out.innerHTML = md.render(clean(text));
  } catch (e) {
    const pre = document.createElement("pre");
    pre.textContent = clean(text);
    out.replaceChildren(pre);
  }
  window.scrollTo(0, 0);
}
</script>
</body>
</html>
`;

const target = path.join(path.dirname(fileURLToPath(import.meta.url)), "Notizbuch", "Antwort.html");
fs.writeFileSync(target, page);
console.log(`${target}: ${(page.length / 1024).toFixed(0)} KB`);
