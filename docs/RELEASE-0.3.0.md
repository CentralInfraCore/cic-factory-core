# cic-factory-core v0.3.0

Az M1 mérésen keresztül. A `v0.2.1` óta hat mért lelet lezárva, két teljes
mérési kör, és két séma-bővítés.

Tag: `core/@v0.3.0` — 19 commit a `core/@v0.2.1` óta.

---

## Miért minor bump

Két dolog miatt, és mindkettő érinti az átvevőt:

1. **A `meta.yaml` négy új mezőt kapott** (`run_id`, `attempt`, `result_digest`,
   `reviewed_run_id`). Régi metákkal visszafelé kompatibilis — a hiányuk „a mező
   bevezetése előtti job"-ot jelent, nem hibát.
2. **A `close-job.sh` mostantól commitol.** Eddig kiírta a parancsokat, és a
   commit az emberé volt.

---

## Az M1 mérésen keresztül

A `v0.2.1` az M0-t zárta le. Ez a kiadás az M1 hét tételéből hatot — de nem úgy,
ahogy az audit leírta.

Hat audit-állítás ment be a mérésbe. **Kettő hamis volt**, egynél volt egy őr,
amit az audit nem említett, egy élesebb volt a beiktatottnál, kettő pontos:

| állítás | verdikt | |
|---|---|---|
| két job keresztbe szennyezi egymás commitjait | reprodukált | #63 |
| elutasított push helyben hagyja a futást | reprodukált, és **egy job is elég** | #64 |
| két indítás ugyanarra a jobra mindkettő `running`-ba jut | **nem reprodukálódott**, 0/6 | #66 |
| a második indítás törli az első workspace-ét | **nem reprodukálódott** | — |
| a megszüntetett futás utólag ír | **nem reprodukálódott** | #65 |
| régi finalizer felülír egy újabb attemptet | reprodukált | #41 |

Két olyanra terveztünk volna, ami nem létezik. A workspace-törlés önmagában
indokolta volna a per-run workspace izolációt — az így ki is került a hatókörből.

A #43 három állítását külön mértük: ott **mind a három igaz volt.**

---

## Amit ez a verzió kikényszerít

| | |
|---|---|
| **a futásnak identitása van** | `run_id` és monoton `attempt`; a `running` átmenet írja |
| **a finalizer csak a sajátját veheti vissza** | a meta `run_id`-jéhez kötve. Mérve, hogy enélkül `error`-ra írta egy újabb attempt állapotát |
| **a lifecycle-commit a saját path-jait viszi** | pathspec a commiton; eddig mindent commitolt, ami stage-elve volt |
| **az elutasított push egyeztet** | fetch, a saját job állapotának ellenőrzése, és csak akkor rebase+retry, ha még mi birtokoljuk az átmenetet |
| **a futó job elvétele döntés** | nem a `read` lezárt stdin-en való hibázásának mellékhatása. `--force` az explicit átvétel |
| **a review megnevezi a futást** | C6: a `review.md` a `run_id`-t, amit nézett. Mérve, hogy enélkül egy új attempt lezárható volt egy korábbi review-jával |
| **a close azt commitolja, amit validált** | a validáció és a kézi commit között eddig kicserélhető volt az output |
| **a kapu nem kérhet kimondatlant** | D5: minden kikényszerített K/O/C szabály dokumentálva a saját parancsában |

**25 suite, 570 check, 7 önálló checker.**

---

## Számok

| | `v0.1.0` | `v0.2.1` | `v0.3.0` |
|---|---|---|---|
| assertion | 104 | 480 | **570** |
| viselkedési suite | 7 | 21 | **25** |
| önálló checker | 2 | 7 | **7** |

---

## Amit NEM garantál

- **A `pending → running` átmenet nem atomi.** A compare-and-swap újraolvassa a
  státuszt közvetlenül az írás előtt, de két folyamat között marad ablak. Ma
  semmi mért eset nem gyakorolja — és mérés nélkül lockot kitalálni rá pontosan
  az a hiba, amit ez a kiadás végig dokumentál.
- **A kötés `run_id`-n áll, nem immutable result ref-en.** A feature branch
  SHA-ja nincs rögzítve: a `done` commitból az látszik, MELYIK futás eredményét
  zárták le, az nem, hogy az az eredmény melyik commitban él.
  ([#44](https://github.com/CentralInfraCore/cic-factory-core/issues/44))
- **Az aláírás nem köti a commit identitását**, és a submodule commitok kimaradnak
  belőle — mérve.
  ([#38](https://github.com/CentralInfraCore/cic-factory-core/issues/38))
- **Az executor-határ félkész.** A runner-szerződés leválasztotta az executort,
  a session-kezelést nem.
  ([#42](https://github.com/CentralInfraCore/cic-factory-core/issues/42))
- **Az agent-hookok tanácsadók.** A valódi határ a remote-oldali elfogadás.
  ([#10](https://github.com/CentralInfraCore/cic-factory-core/issues/10))

---

## Migráció

### 1. A `close-job.sh` commitol

Eddig kiírta a parancsokat. Most elvégzi: `git add` a job path-jaira, commit
pathspec-hez kötve, push. A commit-msg hook ugyanúgy aláírja.

`--no-commit` visszaadja a régi viselkedést, és kiírja a `result_digest`-et,
hogy legalább utólag ellenőrizhető legyen, mit látott a kapu.

### 2. A review nevezze meg a futást (C6)

```
- run_id: <a meta.yaml run_id mezőjéből>
```

A `/job-review` és a `/job-close` is leírja. **A mező bevezetése előtti jobokra
nem vonatkozik:** ha a metában nincs `run_id`, a C6 figyelmeztet és átenged —
ugyanúgy, ahogy a C5 a hiányzó `spec_gate`-tel.

Ami viszont ezután indul, arra vonatkozik.

### 3. A `--force` a futó/lefutott job átvételéhez

A `run-job.sh` eddig `read`-del kérdezett, és lezárt stdin-en azért állt meg,
mert a `read` hibázott — nem azért, mert így döntöttünk. Most nem-interaktív
futásban explicit elutasít, és megmondja, hogy a `--force` az átvétel módja.

Automatizált hívóknak: ahol eddig a prompt véletlenül megállította a második
indítást, ott most ugyanaz történik, csak kimondva.

### 4. A séma négy mezővel bővült

`run_id`, `attempt`, `result_digest`, `reviewed_run_id`. A `validate-meta.sh`
elfogadja a hiányukat; a `jobs/.schema/meta.yaml` sablon tartalmazza őket.

---

## Amit a két mérési kör a módszerről mondott

A `v0.2.0` óta a tézis kettő volt: *egy kapu, ami nem tud pirosat adni,
díszítés*, és *egy terv, ami méretlen állításon áll, ugyanaz.*

Ez a kiadás hozzátette a harmadikat, mert hatszor jött elő:

> **Egy teszt vagy mérés, ami a mutáció előtt és után is ugyanazt mondja, rossz
> dolgot mér** — bármilyen értelmesen olvasható.

A hat esetből egy sem átolvasással derült ki. Mindegyiket az fogta meg, hogy a
verdikt kiírta az **elutasítás okát** is, nem csak az exit code-ot — és hogy a
javítás után újrafuttattuk a mérést, ahelyett hogy késznek vettük volna.

Kétszer maga a mérés volt hibás, nem a kód: egyszer a rossz folyamatot öltem meg
(#65), egyszer a szimulált második attempt nem írt saját `run_id`-t (#41). Mindkettő
a SPEC-be is bekerült volna tényként, ha nem futtatjuk újra.
