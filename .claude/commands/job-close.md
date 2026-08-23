# Job lezárása

Agent befejezése után a lifecycle zárása és az output áthozása a live workdir-ba.

## Kötelező lépések sorrendben

### 1. Output ellenőrzés — ELŐSZÖR OLVASD EL

```bash
CLONE="jobs/$JOB_ID/workspace/cic-factory"
ls "$CLONE/jobs/$JOB_ID/output/"
```

Olvasd el a fő output fájlokat. Lásd `/job-review` skill az értékelési szabályokhoz.

### 2. Output áthozása live workdir-ba

```bash
CLONE="jobs/$JOB_ID/workspace/cic-factory"
LIVE="."

# output fájlok
cp "$CLONE/jobs/$JOB_ID/output/"*.md "jobs/$JOB_ID/output/"

# sub-job specek (ha az agent hozott létre)
for job in $(ls "$CLONE/jobs/" | grep -v "^$JOB_ID$" | grep "^poc-\|^<prefix>-"); do
  mkdir -p "jobs/$job"
  cp "$CLONE/jobs/$job/input.md" "jobs/$job/"
  cp "$CLONE/jobs/$job/meta.yaml" "jobs/$job/"
done
```

### 3. Gépi output-kapu — a forma ellenőrzése géppel

```bash
bash tools/validate-output.sh $JOB_ID
```

Ha **NO-GO** → ne zárd le a jobot. A hiányzó/üres output, a hiányzó claim-evidence
tábla és a hiányzó reachability artifact gépi kérdés — ne te pótold kézzel, és ne
nézd el. Javíttasd az agenttel, vagy írj jobb `input.md`-t.

**Miért itt van:** a drága review (te / erős modell) a TARTALOMRA menjen, ne a formára.
Amit gép el tud dönteni, azt döntse el a gép — a `base-repo-explore-01-finish` jobnál
pont ez a kapu szúrta ki utólag, hogy a spec által megnevezett három output a szülő
job könyvtárába került. Emberi review + merge átengedte.

### 4. Review artifact — `jobs/$JOB_ID/review.md`

**Ez kötelező, és nem az agent írja — te írod.**

A factory minden rétege bizonyítékot termel (Vault-aláírt commit, claim-evidence tábla,
`deadcode` output, headSha). Egy kivétel volt: az orchestrátori review, ami eddig egy
chat-üzenet volt — aláíratlan, nem reprodukálható, a session végén elveszett.
Ez a fájl zárja be azt a rést.

Sablon:

```markdown
# review — <job-id>

- Reviewer: orchestrátor (<modell>)
- Dátum: <ISO 8601>
- Feature branch: feature/<job-id>
- Review-zott commit: <sha>
- run_id: <a meta.yaml run_id mezőjéből>

## Gépi kapuk

| Kapu | Eredmény | Megjegyzés |
|---|---|---|
| `tools/validate-spec.sh` | GO / NO-GO | |
| `tools/validate-output.sh` | GO / NO-GO | |
| CI (ha van) | zöld / n/a | headSha: `<sha>` — egyeztetve a tesztelt committal |

## Amit ténylegesen ellenőriztem

Konkrét predikátumok, nem összefoglaló. Minden sor mellé a parancs vagy a fájl:sor.

| Állítás az outputban | Hogyan ellenőriztem | Eredmény |
|---|---|---|
| pl. „X implemented" | `grep -rn "X" --include="*.go" \| grep -v _test.go` | 3 találat, prod hívó: `core/a.go:42` |
| pl. „112/112 teszt zöld" | nem ellenőriztem — agent állítása | **nem igazolt** |

## Amit NEM ellenőriztem

Sorold fel. A csend nem azt jelenti, hogy rendben van.

## Döntés

MERGE / VISSZAKÜLDVE — indoklás egy mondatban.
```

**Szabály:** ha egy állítás mellé nem tudsz verifikációs módszert írni, az a
„nem igazolt" sorba megy — nem hagyható ki. A cél nem a szép review, hanem az,
hogy a következő session (vagy a felhasználó) meg tudja nézni, mit ellenőriztél
ténylegesen, és mit vettél át az agent summaryjából.

### 5. awaiting_review → done

```bash
bash tools/close-job.sh $JOB_ID
```

Ne kézzel írd át a `meta.yaml`-t. Ez az **egyetlen** átmenet, ami `done`-t ír, és
a script kikényszeríti a feltételeit — ha bármelyik nem teljesül, elutasít és
megnevezi, melyik:

| | feltétel |
|---|---|
| C1 | van `meta.yaml` |
| C2 | a státusz pontosan `awaiting_review` |
| C3 | a `validate-output.sh` GO-t ad |
| C4 | a `review.md` létezik, nem üres, és nincs benne placeholder |
| C5 | ha a futás `--skip-spec-gate`-tel indult, a `review.md` ezt elismeri |
| C6 | a `review.md` megnevezi a `run_id`-t, amit nézett |

A C3 újrafuttatja a 3. pont kapuját. Ez szándékos: a 3. pont azért van, hogy te
**lásd** az eredményt, mielőtt a review-t írod; a C3 azért, hogy a lezárás ne
azon múljon, hogy tényleg lefuttattad-e.

`--dry-run` megnézi a feltételeket anélkül, hogy lezárna.

**A C5-ről.** Ha a `meta.yaml`-ben `spec_gate: "skipped"` áll, ez a job gépi
spec-GO nélkül futott. A menekülőút legális, de a lezárás nem mehet úgy, hogy ez
csak egy mezőben van, amibe senki nem néz. Írd a `review.md`-be:

```
spec_gate: skipped — <mit ellenőriztél helyette, és mit nem tudsz igazolni>
```

Ha a mező üres, a job a mező bevezetése előttről való: a script figyelmeztet, de
átenged. Ilyenkor nem igazolható, hogy a spec-kapu lefutott-e — ezt a
„nem igazolt" sorba írd.

A `usage:` blokk attól függ, melyik úton futott a job:

- **`run-job.sh`** — már kitöltötte a `claude --output-format json`-ból, ne írd át kézzel
- **`/job-run` (Agent tool)** — a `/job-run` 5. pontja tölti ki; ha üres, ott maradt ki

### 6. Commit és push

```bash
bash tools/update-index.sh
git add jobs/$JOB_ID/ jobs/<sub-job-id>/ jobs/index.yaml
git commit -m "job: $JOB_ID — done + output + review"
git push
```

Az `update-index.sh` az `index.yaml`-ba beteszi a job modelljét, költségét és turn-számát,
plus egy `totals:` blokkot. Ez teszi mérhetővé a modell-rétegzés hatását.

### 7. Workspace takarítás (opcionális)

```bash
rm -rf jobs/$JOB_ID/workspace
```

A workspace gitignored, de helyet foglal. Törölhető ha az output már a live workdir-ban van.

## Hibák amiket el kell kerülni

- ❌ A workspace klón `output/`-ját nézni a live workdir `output/` helyett ("jó az anyag" ellenőrzés nélkül)
- ❌ Sub-job speceket nem másolni át — akkor nem futtathatók `run-job.sh`-val
- ❌ done commit előtt nem futtatni `update-index.sh`-t
- ❌ `validate-output.sh` NO-GO mellett lezárni a jobot
- ❌ `review.md` nélkül mergelni — akkor a review nem hagy nyomot, és nem ellenőrizhető utólag
- ❌ A `review.md`-be az agent summaryját átmásolni. Az a review tárgya, nem az eredménye.
