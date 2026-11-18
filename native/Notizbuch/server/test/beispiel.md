---
title: Beispiel für Markdown im Notizbuch
author: Test
---
# Analysis II – Übungsblatt 3

Sei $f:\R^n\to\R$ stetig differenzierbar und $x_0\in\R^n$. Wir zeigen, dass die **Richtungsableitung** in Richtung $v$ durch $\nabla f(x_0)\cdot v$ gegeben ist.

## Aufgabe 1: Kettenregel

Für $g(t) = f(x_0 + t v)$ gilt nach der Kettenregel
$$g'(0) = \sum_{i=1}^n \frac{\partial f}{\partial x_i}(x_0)\, v_i = \langle \nabla f(x_0), v\rangle .$$

Eine sehr lange Formel, die nicht auf die Zeile passt und deshalb kleiner gesetzt wird:
$$\int_0^1 \int_0^1 \int_0^1 \left( x^2 + y^2 + z^2 + \sin(xyz) + \cos(x+y+z) + e^{x y z} + \log(1 + x^2 y^2 z^2) + \frac{x+y}{1+z^2} + \sqrt{1 + x^4 + y^4 + z^4} \right)\, dx\, dy\, dz$$

## Aufgabe 2: Tabelle der Ableitungen

| Funktion | Ableitung | Bemerkung |
|---|---|---|
| $x^n$ | $n x^{n-1}$ | für alle $n \in \N$ |
| $e^x$ | $e^x$ | Fixpunkt des Ableitens |
| $\sin x$ | $\cos x$ | periodisch |
| $\log x$ | $1/x$ | nur für $x>0$; dieser Text ist absichtlich lang, damit die Zelle umbrechen muss |

## Aufgabe 3: Numerisch

```python
def gradient(f, x, h=1e-6):
    return [(f([x[j] + (h if j == i else 0) for j in range(len(x))]) - f(x)) / h for i in range(len(x))]  # lange Zeile
```

> Mathematik ist die Kunst, verschiedenen Dingen denselben Namen zu geben. — Henri Poincaré

- Ein Punkt mit [Link](https://de.wikipedia.org/wiki/Kettenregel)
- Ein Punkt mit nackter Adresse https://de.wikipedia.org/wiki/Gradient_(Mathematik)
  1. verschachtelt
  2. noch einer

\[ \det\begin{pmatrix} a & b \\ c & d \end{pmatrix} = ad - bc \]

## Aufgabe 4: Satz von Taylor

Ist $f$ zweimal stetig differenzierbar, so gilt für $h \to 0$
$$f(x_0 + h) = f(x_0) + \nabla f(x_0)\cdot h + \tfrac12\, h^{\mathsf T} H_f(x_0)\, h + o(\|h\|^2),$$
wobei $H_f$ die Hesse-Matrix ist. Ist $\nabla f(x_0) = 0$ und $H_f(x_0)$ positiv definit, so hat $f$ in $x_0$ ein strenges lokales Minimum. Ist $H_f(x_0)$ indefinit, so liegt ein Sattelpunkt vor.

Beweisidee: Wegen der Stetigkeit der zweiten Ableitungen ist $H_f$ in einer Umgebung von $x_0$ positiv definit; mit dem Mittelwertsatz in Integralform folgt
$$f(x_0+h) - f(x_0) = \int_0^1 (1-t)\, h^{\mathsf T} H_f(x_0 + t h)\, h \, dt > 0 \quad\text{für } 0 < \|h\| < \delta.$$

## Aufgabe 5: Lagrange-Multiplikatoren

Gesucht sind die Extrema von $f(x,y) = x^2 + 2y^2$ unter der Nebenbedingung $g(x,y) = x^2 + y^2 - 1 = 0$. Die Bedingung $\nabla f = \lambda \nabla g$ liefert
$$2x = 2\lambda x, \qquad 4y = 2\lambda y, \qquad x^2 + y^2 = 1.$$
Also ist $x = 0$ oder $\lambda = 1$, und $y = 0$ oder $\lambda = 2$. Die Kandidaten sind $(\pm 1, 0)$ mit $f = 1$ und $(0, \pm 1)$ mit $f = 2$: Das Minimum ist $1$, das Maximum $2$.

## Aufgabe 6: Ausblick

Die folgenden Absätze füllen die Seiten, damit der Umbruch zwischen Seiten zu sehen ist. Eine Überschrift steht nie allein unten auf einer Seite, und keine Zeile, Formel oder Tabellenzeile wird an einem Seitenrand durchgeschnitten.

Der Satz über implizite Funktionen sagt: Ist $F:\R^{n}\times\R^{m}\to\R^m$ stetig differenzierbar, $F(a,b)=0$ und $\partial_y F(a,b)$ invertierbar, so gibt es Umgebungen $U \ni a$ und $V \ni b$ und eine stetig differenzierbare Funktion $\varphi: U \to V$ mit $F(x,y) = 0 \iff y = \varphi(x)$ für $(x,y)\in U\times V$. Ihre Ableitung ist $\varphi'(x) = -\partial_y F(x,\varphi(x))^{-1}\, \partial_x F(x,\varphi(x))$.

Der Satz über die Umkehrfunktion folgt daraus mit $F(x,y) = f(y) - x$: Ist $f'(b)$ invertierbar, so ist $f$ nahe $b$ umkehrbar, und die Umkehrfunktion ist stetig differenzierbar mit $(f^{-1})'(f(y)) = f'(y)^{-1}$.

Für Kurvenintegrale gilt: Ist $\omega = \sum_i a_i\,dx_i$ exakt, also $\omega = dF$, so hängt $\int_\gamma \omega = F(\gamma(1)) - F(\gamma(0))$ nur von den Endpunkten ab. Auf sternförmigen Gebieten ist jede geschlossene Form exakt (Lemma von Poincaré).

Der Satz von Fubini erlaubt, Mehrfachintegrale als iterierte Integrale zu berechnen, sofern $\int |f| < \infty$; ohne diese Voraussetzung können die iterierten Integrale verschieden sein, etwa für $f(x,y) = \frac{x^2-y^2}{(x^2+y^2)^2}$ auf $(0,1)^2$.

Die Transformationsformel lautet $\int_{\Phi(U)} f(y)\,dy = \int_U f(\Phi(x))\,|\det D\Phi(x)|\,dx$ für einen Diffeomorphismus $\Phi$; mit Polarkoordinaten ergibt sich daraus $\int_{\R^2} e^{-|x|^2}\,dx = \pi$ und damit $\int_\R e^{-t^2}\,dt = \sqrt{\pi}$.
