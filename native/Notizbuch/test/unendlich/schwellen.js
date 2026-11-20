// Vergleicht detector.js mit Notizbuch/InfinityGesture.swift der App: dieselben Schwellen (T hier, private static let
// dort) mit denselben Werten, und dieselben Zahlen in der Logik der Erkennung (ohne 0, 1 und 2). Aufruf:
// node schwellen.js; erwartet „Schwellen und Zahlen gleich“.
"use strict";
const fs = require("fs");
const path = require("path");
const { T } = require("./detector.js");

const swift = fs.readFileSync(path.join(__dirname, "..", "..", "Notizbuch", "InfinityGesture.swift"), "utf8");
const js = fs.readFileSync(path.join(__dirname, "detector.js"), "utf8");
let bad = 0;
const fail = (text) => { bad++; console.log("ANDERS: " + text); };

// 1. Schwellen
const own = {};
for (const m of swift.matchAll(/private static let (\w+)(?:: CGFloat)? = ([0-9.]+)\s*$/gm)) own[m[1]] = Number(m[2]);
for (const k of Object.keys(T)) {
  if (!(k in own)) fail(`${k} fehlt in InfinityGesture.swift`);
  else if (own[k] !== T[k]) fail(`${k}: Swift ${own[k]}, JS ${T[k]}`);
}
for (const k of Object.keys(own)) if (!(k in T)) fail(`${k} fehlt in detector.js (T)`);

// 2. Zahlen in der Logik: Kommentare und Texte weg, dann jede Zahl außer 0, 1, 2 (Schleifen, Indizes, 2π) zählen
const code = (text) => text
  .replace(/\/\/.*$/gm, "")
  .replace(/"(?:[^"\\\n]|\\.)*"|`(?:[^`\\]|\\.)*`/g, '""');
const numbers = (text) => {
  const count = {};
  for (const m of code(text).matchAll(/(?<![\w.])\d+(?:\.\d+)?(?:e-?\d+)?(?![\w.])/g)) {
    const v = Number(m[0]);
    if (v !== 0 && v !== 1 && v !== 2) count[v] = (count[v] || 0) + 1;
  }
  return count;
};
const between = (text, from, to) => {
  const a = text.indexOf(from), b = to ? text.indexOf(to, a) : text.length;
  if (a < 0 || b < 0) throw new Error(`Stelle nicht gefunden: ${from} … ${to}`);
  return text.slice(a, b);
};
// Swift: detect und die Geometrie (ohne spot/context, die nur die App braucht); JS: alles außer T und den Exporten
const swiftLogic = between(swift, "static func detect", "static func spot") + between(swift, "// MARK: Geometrie", null);
const jsLogic = between(js, "const dist =", "module.exports");
const a = numbers(swiftLogic), b = numbers(jsLogic);
for (const v of new Set([...Object.keys(a), ...Object.keys(b)])) {
  if ((a[v] || 0) !== (b[v] || 0)) fail(`Zahl ${v}: Swift ${a[v] || 0}-mal, JS ${b[v] || 0}-mal`);
}

console.log(`Schwellen: ${Object.keys(T).length} in JS, ${Object.keys(own).length} in Swift`);
console.log(`Zahlen in der Logik: ${JSON.stringify(a)}`);
console.log(bad ? `${bad} Unterschiede` : "Schwellen und Zahlen gleich");
process.exitCode = bad ? 1 : 0;
