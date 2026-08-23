# Job review — delegálási ellenőrzés

Amikor egy agent job outputját értékeled, követd ezt a sorrendet:

## 0. Előbb a gép — `validate-output.sh`

```bash
bash tools/validate-output.sh <job-id>
```

NO-GO → **ne olvasd tovább**. A hiányzó output, a hiányzó claim-evidence tábla és a
hiányzó reachability artifact formai kérdés; ne pazarold rá a drága figyelmet.
Javíttasd, futtasd újra, és csak GO után gyere ide.

A te figyelmed a **tartalomra** kell menjen: igaz-e amit állít, és mivel bizonyítja.

## 1. Olvasd el az output fájlokat

Az agent munkakörnyezetéből (`jobs/<job-id>/output/`). Csak a szöveget olvasd — ne kérdezd le a KB-t.

## 2. Döntési pont: van-e alapvető architektúrális hiba?

**Igen** → Ne kérdezd le a KB-t részletekért. Írj jobb `input.md`-t és futtasd újra az agentet.

**Nem** → Spot-check: legfeljebb 2-3 célzott KB lekérdezés egy konkrét állítás ellenőrzésére.

## 3. Ha hiányt találsz — NE te kutasd fel

A helyes reakció:
```
→ input.md frissítése: "kérdezd le X területet is"
→ agent újrafuttatása
```

A hibás reakció:
```
→ Te lekérdezed a KB-t
→ megtalálod a hiányt
→ beírod az input.md-be
→ újra ugyanez
```

## Alapszabály

> Az orchestrátor jó kérdéseket ír. Az agent válaszol.
> Ha te válaszolsz a saját kérdéseidre, kihagyod az agentet.

## Jelek hogy rossz úton vagy

- Több mint 3 KB lekérdezést teszel értékelés közben
- Az `input.md`-t a saját KB lekérdezéseid alapján bővíted
- Azt mondod "jó az anyag" anélkül hogy az output fájlokat elolvastad volna
- A workspace klón tartalmát nézed a live workdir `output/` helyett
- Formai hibákat javítgatsz kézzel ahelyett, hogy a `validate-output.sh`-ra bíznád

## A review nyomot hagy

A review eredménye nem chat-üzenet, hanem **`jobs/<job-id>/review.md`** — lásd
`/job-close` 4. pontját a sablonért.

**A review nevezze meg, melyik futást nézte.** A `meta.yaml` `run_id` mezőjéből
másold be:

```
- run_id: <a meta.yaml run_id mezőjéből>
```

Enélkül a `close-job.sh` C6 feltétele elutasít. Nem formalitás: mérve, hogy
enélkül egy ÚJ attempt lezárható volt egy KORÁBBI attempt review-jával — a close
a fájl meglétét látta, azt nem, melyik futáshoz készült. Amit nem ellenőriztél, azt írd be a
„nem igazolt" sorba. Egy review, ami csak annyit mond hogy „átnéztem, jó",
pontosan annyit ér, mint az agent summaryja, amit felül kellett volna vizsgálnia.
