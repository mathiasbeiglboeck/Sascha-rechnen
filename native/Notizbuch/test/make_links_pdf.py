#!/usr/bin/env python3
"""Baut links.pdf: ein Test-PDF mit Links an Stellen im selben Dokument (für die Vorschau beim Halten des Radierers).

Seite 1 hat sechs Links in verschiedenen Formen, wie sie PDFs aus LaTeX (hyperref) oder Word enthalten:
  0 explizites Ziel (Seite 3, y 500)
  1 benanntes Ziel über „Gehe zu“ (Seite 2, y 300, im Namensbaum wie bei LaTeX)
  2 benanntes Ziel direkt am Link (Seite 2, y 600, Namensbaum)
  3 „Gehe zu“ mit explizitem Ziel „ganze Seite“ (Seite 2)
  4 Internet (zählt nicht)                  5 Befehl „nächste Seite“ (zählt nicht)
Benannte Ziele im alten /Dests-Wörterbuch (wie aus Chrome) deckt links-browser.pdf ab (make_links_browser.js).
Seite 3 hat einen beschnittenen Rahmen (CropBox) und einen Link zurück, Seite 4 ist gedreht und hat einen Link.
Jedes Ziel ist auf seiner Seite mit einer roten Linie markiert, die Schrift „Ziel …“ steht direkt darunter.

Mit --big N statt dessen ein großes PDF mit N Seiten und je 30 Links (Dauer des Lesens im Hintergrund prüfen).

Aufruf: python3 make_links_pdf.py [--big N] [Ausgabe.pdf]   (nur Python 3, keine weiteren Pakete)
"""
import sys

# Breiten der Zeichen von Helvetica (je 1000 Einheiten Schriftgröße), Zeichen 32 bis 126
HELVETICA = [278, 278, 355, 556, 556, 889, 667, 191, 333, 333, 389, 584, 278, 333, 278, 278, 556, 556, 556, 556, 556,
             556, 556, 556, 556, 556, 278, 278, 584, 584, 584, 556, 1015, 667, 667, 722, 722, 667, 611, 778, 722, 278,
             500, 667, 556, 833, 722, 778, 667, 778, 722, 667, 611, 722, 667, 944, 667, 667, 611, 278, 278, 278, 469,
             556, 333, 556, 556, 500, 556, 556, 278, 556, 556, 222, 222, 500, 222, 833, 556, 556, 556, 556, 333, 500,
             278, 556, 500, 722, 500, 500, 500, 334, 260, 334, 584]
UMLAUTE = {"ä": 556, "ö": 556, "ü": 556, "Ä": 667, "Ö": 778, "Ü": 722, "ß": 611}


def stringWidth(text, font, size):
    return sum(UMLAUTE.get(ch) or HELVETICA[ord(ch) - 32] for ch in text) * size / 1000


def pdf_string(text):
    out = []
    for ch in text:
        if ch in "()\\":
            out.append("\\" + ch)
        elif ord(ch) < 128:
            out.append(ch)
        else:
            out.append("\\%03o" % ch.encode("cp1252")[0])
    return "(" + "".join(out) + ")"


objects = {}


def obj(num, body):
    objects[num] = body


args = sys.argv[1:]
big = 0
if args[:1] == ["--big"]:
    big = int(args[1])
    args = args[2:]
n_pages = big or 4

CATALOG, PAGES, FONT, NAMETREE = 1, 2, 3, 4
P = list(range(5, 5 + n_pages))                 # Seiten
C = list(range(5 + n_pages, 5 + 2 * n_pages))   # Inhalte
next_annot = [5 + 2 * n_pages]                  # Links


def ref(n):
    return "%d 0 R" % n


def text(x, y, s, size=14, color="0 0 0"):
    return "BT /F1 %d Tf %s rg %.1f %.1f Td %s Tj ET\n" % (size, color, x, y, pdf_string(s))


def link_line(x, y, s, action, annots, content):
    """Blauer, unterstrichener Text mit einem Link darüber"""
    w = stringWidth(s, "Helvetica", 14)
    content.append(text(x, y, s, color="0 0 0.8"))
    content.append("0 0 0.8 RG 0.8 w %.1f %.1f m %.1f %.1f l S\n" % (x, y - 3, x + w, y - 3))
    n = next_annot[0]
    next_annot[0] += 1
    obj(n, "<< /Type /Annot /Subtype /Link /Rect [%.1f %.1f %.1f %.1f] /Border [0 0 0] %s >>"
        % (x - 1, y - 5, x + w + 1, y + 13, action))
    annots.append(n)


def target_mark(y, label, content, x0=40, x1=555):
    content.append("1 0 0 RG 1.5 w %.1f %.1f m %.1f %.1f l S\n" % (x0, y, x1, y))
    content.append(text(x0 + 4, y - 16, label, color="0.8 0 0"))


def filler(y_from, y_to, content, x=72):
    y = y_from
    i = 1
    while y > y_to:
        content.append(text(x, y, "Zeile %d: Füllschrift, damit man die Lage der Ziele sieht." % i, size=11,
                            color="0.45 0.45 0.45"))
        y -= 22
        i += 1


pages = []


def big_pages():
    """N Seiten mit je 30 Links an verschiedene Stellen, halb benannt (wie LaTeX), halb explizit"""
    names = {}
    for i in range(big):
        content, annots = [text(72, 800, "Seite %d von %d" % (i + 1, big), size=16)], []
        for k in range(30):
            j = (i * 7 + k * 13 + 1) % big
            y = 100 + (i + k) * 37 % 650
            label = "Link %d: zu Seite %d, y %d" % (k + 1, j + 1, y)
            if k % 2:
                name = "p%dy%d" % (j, y)
                names[name] = "[%s /XYZ 0 %d 0]" % (ref(P[j]), y)
                action = "/A << /S /GoTo /D (%s) >>" % name
            else:
                action = "/Dest [%s /XYZ 0 %d 0]" % (ref(P[j]), y)
            link_line(72, 770 - k * 23.5, label, action, annots, content)
        pages.append(("/MediaBox [0 0 595 842]", content, annots))
    return " ".join("(%s) %s" % (n, names[n]) for n in sorted(names))


def test_pages():
    """Die vier Seiten von links.pdf (siehe oben)"""
    # Seite 1: die Links
    c1, a1 = [], []
    c1.append(text(72, 780, "Links-Test", size=24))
    c1.append(text(72, 752, "Radierer 1,5 s still auf einen blauen Link halten.", size=12, color="0.3 0.3 0.3"))
    link_line(72, 700, "0: Ziel A (Seite 3, explizites Ziel)", "/Dest [%s /XYZ 0 500 0]" % ref(P[2]), a1, c1)
    link_line(72, 660, "1: Ziel B (Seite 2, benannt, Gehe zu)", "/A << /S /GoTo /D (zielB) >>", a1, c1)
    link_line(72, 620, "2: Ziel C (Seite 2, benannt)", "/Dest (zielC)", a1, c1)
    link_line(72, 580, "3: Seite 2 (ganze Seite, Gehe zu)", "/A << /S /GoTo /D [%s /Fit] >>" % ref(P[1]), a1, c1)
    link_line(72, 540, "4: example.com (Internet, keine Vorschau)",
              "/A << /S /URI /URI (https://example.com/) >>", a1, c1)
    link_line(72, 500, "5: Nächste Seite (Befehl, keine Vorschau)", "/A << /S /Named /N /NextPage >>", a1, c1)
    filler(440, 80, c1)
    pages.append(("/MediaBox [0 0 595 842]", c1, a1))

    # Seite 2: Ziele B (y 300) und C (y 600)
    c2 = [text(72, 790, "Seite 2", size=20)]
    filler(760, 620, c2)
    target_mark(600, "Ziel C (y = 600)", c2)
    filler(560, 320, c2)
    target_mark(300, "Ziel B (y = 300)", c2)
    filler(260, 60, c2)
    pages.append(("/MediaBox [0 0 595 842]", c2, []))

    # Seite 3: beschnitten, Ziel A (y 500), Link zurück nach oben auf Seite 1
    c3, a3 = [text(72, 760, "Seite 3 (beschnittener Rahmen)", size=20)], []
    link_line(72, 720, "Zurück zum Anfang (Seite 1 oben)", "/Dest [%s /XYZ 0 842 0]" % ref(P[0]), a3, c3)
    filler(680, 520, c3)
    target_mark(500, "Ziel A (y = 500)", c3, x0=60, x1=535)
    filler(460, 60, c3)
    pages.append(("/MediaBox [0 0 595 842] /CropBox [40 40 555 802]", c3, a3))

    # Seite 4: gedreht, Link zur ganzen Seite 2
    c4, a4 = [text(72, 520, "Seite 4 (gedreht)", size=20)], []
    link_line(72, 470, "Zu Seite 2 (ganze Seite)", "/Dest [%s /Fit]" % ref(P[1]), a4, c4)
    filler(420, 300, c4)
    pages.append(("/MediaBox [0 0 595 842] /Rotate 90", c4, a4))

    # Namen sortiert, wie es ein Namensbaum verlangt
    return "(zielB) [%s /XYZ 0 300 0] (zielC) [%s /XYZ 0 600 0]" % (ref(P[1]), ref(P[1]))


name_entries = big_pages() if big else test_pages()
obj(CATALOG, "<< /Type /Catalog /Pages %s /Names << /Dests %s >> >>" % (ref(PAGES), ref(NAMETREE)))
obj(PAGES, "<< /Type /Pages /Kids [%s] /Count %d >>" % (" ".join(ref(p) for p in P), len(P)))
obj(FONT, "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>")
obj(NAMETREE, "<< /Names [%s] >>" % name_entries)
for i, (box, content, annots) in enumerate(pages):
    stream = "".join(content).encode("cp1252")
    obj(C[i], b"<< /Length %d >>\nstream\n" % len(stream) + stream + b"\nendstream")
    annot = " /Annots [%s]" % " ".join(ref(a) for a in annots) if annots else ""
    obj(P[i], "<< /Type /Page /Parent %s %s /Resources << /Font << /F1 %s >> >> /Contents %s%s >>"
        % (ref(PAGES), box, ref(FONT), ref(C[i]), annot))

out = bytearray(b"%PDF-1.4\n%\xe2\xe3\xcf\xd3\n")
offsets = {}
for num in sorted(objects):
    offsets[num] = len(out)
    body = objects[num]
    out += b"%d 0 obj\n" % num + (body if isinstance(body, bytes) else body.encode("latin-1")) + b"\nendobj\n"
size = max(objects) + 1
xref = len(out)
out += b"xref\n0 %d\n" % size
out += b"0000000000 65535 f \n"
for num in range(1, size):
    out += b"%010d 00000 n \n" % offsets[num]
out += b"trailer\n<< /Size %d /Root %s >>\nstartxref\n%d\n%%%%EOF\n" % (size, ref(CATALOG).encode(), xref)

path = args[0] if args else ("links-big.pdf" if big else "links.pdf")
with open(path, "wb") as f:
    f.write(out)
print(path, len(out), "Bytes")
