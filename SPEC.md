# SPEC — a factory működési modellje

Ez a dokumentum a `cic-factory-core` **terméke**: az a konvenció, amit a
`tools/` és a `.claude/commands/` megvalósít. Aki a core-ra épít, ezt olvassa.

A CIC-specifikus használat — ökoszisztéma-térkép, repo path-ok, MCP szerver,
felülvizsgált döntések — nem itt él, hanem a
[`cic-factory`](https://github.com/CentralInfraCore/cic-factory) `CLAUDE.md`-jében.
Az a kérdés, hogy *hogyan használja ezt a CIC*; ez a dokumentum arra felel, hogy
*mit tud a gyár általánosan*.

---

## Szerepek

| Szereplő | Hol él | Mit csinál |
|---|---|---|
| Orchestrátor | a live munkakönyvtár | job spec létrehozás, review, merge döntés |
| Agent | `jobs/<job-id>/workspace/<repo>/` (klón) | klónban dolgozik, feature branch-re commitol és pushol |

Az agent **nem** dolgozik a live munkakönyvtárban.

---

## Job lifecycle

```
orchestrátor: input.md + meta.yaml → commit main → push          [pending]
run-job.sh:   spec-kapu → running commit → workspace klón → feature branch
agent:        olvas jobs/<job-id>/ → ír output/ → commitol + pushol feature/<job-id>
run-job.sh:   agent exit 0 → awaiting_review                     [NEM done]
orchestrátor: close-job.sh (output-kapu + review.md) → done → merge main
```

Az állapotgép:

```
pending → running → awaiting_review → done
                 \→ error
```

### `agent_done` ≠ `done`

Az agent exit 0-ja egy állítás **az agentről**: befejezte. A `done` egy állítás
**a jobról**: a kimenete elfogadható. A kettő különböző dolog, két külön
állapottal és két külön jogosultsággal.

Az `awaiting_review → done` átmenetet kizárólag a `close-job.sh` végzi, és csak
akkor, ha az output-kapu GO-t adott és a `review.md` létezik. A `run-job.sh`
egyiket sem teszi, tehát nincs mire alapoznia — ezért gépileg sem tud `done`-t
írni.

### Lease

A `running` állapot commitolva és pusholva van, mielőtt az agent elindul. Ha a
wrapper ezután meghal anélkül, hogy javítaná, a remote egy nem futó jobot
hirdetne. A `run-job.sh` ezért a `running` committal együtt kiír egy határidőt
(`lease_expires`), amiből **a halott folyamat közreműködése nélkül** eldönthető,
hogy egy job elakadt-e. A `check-stale-jobs.sh` ezt olvassa.

Határidő és nem heartbeat: a heartbeatet olyasminek kellene folyamatosan írnia,
ami már halott lehet.

---

## A nyolc use case — a core külső szerződése

A fenti állapotgép azt mondja meg, milyen állapotok vannak. Ez a szakasz azt,
hogy **mit ígér a core annak, aki kívülről hívja** — egy adapter fejlesztőjének,
egy orchestrátornak, egy verifikálónak.

Minden use case négy dolgot rögzít, és egy ötödiket, ami nélkül a többi
félrevezető lenne:

| | |
|---|---|
| **Precondition** | mi igaz, mielőtt a lépés elkezdődik |
| **Transition** | melyik állapotátmenet történik, és mi végzi |
| **Postcondition** | mi igaz utána — beleértve, hogy mi NEM |
| **Evidence** | melyik artifact bizonyítja, hogy megtörtént |
| **Státusz** | `garantált`, `részleges` vagy `még nem` |

A státusz nem díszítés. A `még nem` azt jelenti, hogy a sequence a szándékot
írja le, nem a viselkedést, és megnevezi azt az issue-t, ami lezárná. Egy
szerződés, ami többet állít a megvalósításnál, rosszabb, mint ha nem lenne —
a `tools/check-sequences.sh` ezért gépileg ellenőrzi, hogy minden use case
mind az öt részt hordozza.

Kanonikus végrehajtási út: **`tools/run-job.sh`**. A `/job-run` slash-command
ugyanezt hívja; nincs második út, ami megkerülné a kapukat.

---

### UC-01 — Spec létrehozása

**Státusz:** `garantált`

**Precondition:** a külső réteg már formalizálta az igényt. A core nem értelmez
issue-t, nem old fel környezetet — ezt kapja készen.

**Transition:** nincs. A job `pending`-ként jön létre.

```
orchestrátor → jobs/<id>/input.md + meta.yaml
             → validate-meta.sh   (séma)
             → validate-spec.sh   (K1, K3, K4, K7, K7b, K8, K9, K10, K11)
             → commit main + push
```

**Postcondition:** csak validált, azonosítható spec válik futtathatóvá. A
`meta.yaml` megfelel a `jobs/.schema/meta.schema.json`-nak, a `job_id` egyezik a
könyvtárnévvel.

**Evidence:** a `pending` commit, és a spec-kapu kimenete.

---

### UC-02 — Sikeres végrehajtás

**Státusz:** `garantált`

**Precondition:** a job `pending`, a spec-kapu GO-t adott (vagy a futás
`--skip-spec-gate`-tel indult, és ez rögzítve van).

**Transition:** `pending → running`, majd `running → awaiting_review`. Mindkettőt
a `run-job.sh` végzi.

```
run-job.sh → meta-set: status=running, lease_expires, spec_gate
           → commit + push          (a running állapot a remoten van, mielőtt
                                     bármi elindul)
           → workspace klón, feature/<job-id>
           → runner (RUNNER-CONTRACT.md)
           → meta-set: status=awaiting_review, usage
           → commit + push
```

**Postcondition:** az executor sikere **nem** ír `done` állapotot. A
`run-job.sh` egyetlen úton sem tud `done`-t írni: nincs birtokában sem
output-kapu-eredmény, sem review.

**Evidence:** az `awaiting_review` commit, a `usage` blokk, a feature branch a
remoten.

---

### UC-03 — Hiba, resume és retry

**Státusz:** `részleges` — a késői eredmény elutasítása hiányzik (#41)

**Precondition:** a job `running`, és a futás megszakad.

**Transition:** `running → error`. A finalizer végzi, de **csak** ha ugyanez a
folyamat állította `running`-ra (`WE_SET_RUNNING`).

```
wrapper meghal → finalizer → meta-set: status=error, error_message, lease_expires=""
                           → update-index.sh
                           → commit + push
```

**Postcondition:** a remote nem mutat futó jobot. Az `error` állapot mellett az
index is `error`-t mond.

**Amit még nem garantál:** a `--resume` nem köti magát futásazonosítóhoz, mert
olyan még nincs. Egy leváltott futás késői eredményét semmi nem utasítja el. Az
`error` státusz jelentheti azt is, hogy az agent még dolgozik: a finalizer
szándékosan nem öli meg, és ezt a `test-run-job-finalizer.sh` méri is.

Célzottan megmérve (#65, `tools/measure-concurrency.sh` 6. és 7. eset):

**Ami NEM reprodukálódik:** a megszüntetett futás runner-gyereke nem tud írni a
metába. Csak a `CIC_RESULT_JSON`-t írja, amit a halott wrapper már nem olvas
el. Egy korábbi „megfigyelés" az ellenkezőjét állította — az mérési hiba volt:
a `$!` az alhéj pid-je, nem a wrapperé, tehát a `kill` árván hagyta a wrappert,
ami befejezte a munkát. A rossz folyamatot öltem meg.

**Ami reprodukálódik:** az A futás finalizere `error`-ra írja azt az állapotot,
amit egy újabb B attempt állított be. A finalizer őre (`WE_SET_RUNNING` és
`status == running`) nem tudja megkülönböztetni B `running`-ját a sajátjától —
nincs mihez kötnie. Ez a legerősebb közvetlen bizonyíték arra, hogy futás-
identitás kell. **#41.**

**Evidence:** az `error` commit, az `error_message`, a job-napló.

---

### UC-04 — Review és close

**Státusz:** `részleges` — a kötés a run_id-n áll, nem result ref-en (#44)

**Precondition:** a job `awaiting_review`, van `review.md` és van `output/`.

**Transition:** `awaiting_review → done`. **Kizárólag** a `close-job.sh` végzi.

```
close-job.sh → C1  van meta.yaml
             → C2  a státusz awaiting_review           (meta-get, fail closed)
             → C3  validate-output.sh GO               (O1–O5)
             → C4  review.md létezik és nem üres
             → C5  ha spec_gate=skipped, a review elismeri
             → C6  a review megnevezi a futást, amit nézett (run_id)
             → meta-set: status=done
```

**Postcondition:** minden `done` úton lefutott az output-kapu, és van review
artifact. Nincs olyan dokumentált út, ahol a `done` ezek nélkül elérhető.

**Mérve és lezárva (#43):** a review-nak meg kell neveznie a `run_id`-t, amit
nézett (C6), a close rögzíti a `reviewed_run_id`-t és a validált tartalom
`result_digest`-jét, és **azt commitolja, amit validált** — a validáció és a
commit között eddig kicserélhető volt az output, és a `done` commit olyan
tartalmat vitt, amit a kapu soha nem látott.

**Amit még nem garantál:** a kötés a `run_id`-n áll, nem immutable result
ref-en. A feature branch SHA-ja nincs rögzítve, tehát a `done` commitból az
látszik, MELYIK futás eredményét zárták le, az nem, hogy az az eredmény melyik
commitban él. **#43** lezárva, a teljesebb kötés a **#44** proof-profiljával
jön.

**Evidence:** a `done` commit, a `review.md`, az output-kapu kimenete.

---

### UC-05 — Különböző jobok párhuzamosan

**Státusz:** `még nem` — #41

**Precondition:** két job, két külön `job_id`.

**Transition:** kettő, egymástól függetlenül.

**Amit a core ma tud:** mindkét futás ugyanazt a live checkoutot, ugyanazt a
Git indexet és ugyanazt a `jobs/index.yaml`-t írja. Nincs lock, nincs külön
worktree, és a lifecycle commit nem pathspecifikus.

**Postcondition:** *(amit a lezárása jelentene)* nincs cross-job fájl, stage,
session vagy ref.

**Evidence:** barrier-alapú konkurencia-mérés (2026-08-23, a #41 kommentjében).
Két job párhuzamosan, determinisztikus szinkronizációval — nem `sleep`-pel.

**Amit a mérés mutatott — reprodukálódott:**

Mindkét job befejeződött (`awaiting_review`, exit 0), tehát nem vesznek el
egymás munkájában. A lifecycle-commitok viszont keresztbe visznek:

```
job: beta — running  →  jobs/alpha/input.md
job: beta — running  →  jobs/alpha/meta.yaml
job: beta — running  →  jobs/index.yaml
```

A következmény nem adatvesztés, hanem **bizonyíték-szennyezés**: a beta `done`
commitja már nem izolálja, mit csinált a beta.

Ez a rész nem igényel futás-identitást — a lifecycle-commit pathspec-hez
kötése önmagában megoldja, és önállóan szállítható. #41.

**Amit a mérés NEM mutatott:** a push-verseny viszont igen — két külön
checkoutból a második push non-fast-forward hibával elutasításra kerül, a job
`error` lesz, és a helyi `main` olyan lifecycle-állapottal marad előrébb,
amiről a remote nem tud. Nincs fetch/rebase/retry. Ez az, ami ma ténylegesen
veszít állapotot.

Amíg ez nem zárul le, a szerződés annyi: **egy orchestrátor, egy checkout,
egyszerre egy job.**

---

### UC-06 — Ugyanaz a job versengő indítása

**Státusz:** `részleges` — #41

**Precondition:** két folyamat ugyanarra a `job_id`-ra.

**Amit a core ma tud:** többet, mint amennyit az audit alapján gondoltunk. A
`run-job.sh` beolvassa a státuszt, és ha az már `running`, megáll:

```
[WARN] Job már fut. Folytatod? (y/N)
```

Nem-interaktívan (lezárt stdin) elutasít, exit 1.

**Amit a mérés mutatott — NEM reprodukálódott:**

0,3 másodperces késleltetéssel **és** öt teljesen egyidejű indítással: 5/5-ben
a második megállt. Mivel a workspace-lépésig el sem jut, az `rm -rf` sem
történik meg — a workspace-be tett canary minden futásban túlélte.

**Ez nem compare-and-swap.** Valós olvasás-írás ablak van, lock nélkül, és a
`WE_SET_RUNNING` lokális boolean: azt jelzi, hogy MI állítottuk `running`-ra,
nem azt, hogy még mindig mi birtokoljuk a jobot. De a naiv „mindkettő átmegy"
egyetlen mért futásban sem következett be.

A különbség számít a tervezésnél: ezt **keményíteni** kell, nem nulláról
megépíteni. #41.

**Transition:** *(amit a lezárása jelentene)* `pending → running`, de compare-and-
swap-pel: várt állapot, várt revízió és futás-identitás ellenőrzésével.

**Postcondition:** *(amit a lezárása jelentene)* pontosan egy futás kap workspace-t
és publikálási jogosultságot; a vesztes nem kap egyiket sem.

**Evidence:** *(amit bizonyítania kellene)* két egyidejű claim ugyanarra a jobra,
barrierrel szinkronizálva, pontosan egy nyertessel.

**Ez sincs mérve.** #41.

---

### UC-07 — Executorfüggetlen végrehajtás

**Státusz:** `garantált`

**Precondition:** a runner megfelel a `docs/RUNNER-CONTRACT.md`-nek.

**Transition:** nincs saját; a UC-02 belsejében történik.

```
run-job.sh → CIC_PROMPT_FILE, CIC_RESULT_JSON, CIC_RUN_LOG
           → tools/runners/<név>.sh
           → runner-result.schema.json szerinti JSON
```

**Postcondition:** a core lifecycle-szemantikája nem függ attól, melyik runner
futott. A `tools/runners/echo.sh` ugyanazon a szerződésen fut, mint a
`claude.sh`, és a `test-run-job-e2e.sh` a teljes `pending → done` utat vele
viszi végig — agent, hálózat és költség nélkül. A `done` ott sem rövidít: a
lezárás ugyanúgy a `close-job.sh`-n megy át, tehát a `validate-output.sh`
output-kapuján és a `review.md` meglétén is. Egy runner nem tud olyan utat
nyitni, ami ezeket megkerüli.

**Amit még nem garantál:** a `--resume` egyáltalán nem része a runner-
szerződésnek: Claude session-jsonl-t vár, tehát egy másik executor nem tudná
implementálni. Az agent-konfiguráció helyét mostantól a job mondja meg
(`agent.config_dir`), de a fallback és a session-elrendezés ismerete még a
magban van. **#42.**

**Evidence:** a runner JSON-ja, az `agent-output-*.md`, a `usage` blokk.

---

### UC-08 — Proof és offline verifikáció

**Státusz:** `részleges` — a bizonyíték a commit kontextusát köti, az OID-jét nem (#44)

**Precondition:** a commitok Vault-aláírással készültek.

**Transition:** nincs; ez a lezárt állapot ellenőrzése.

```
verify-signatures.sh → a commit üzenetéből a signing blokk
                     → a manifest-verzió szerinti digest újraszámítása
                     → ECDSA-ellenőrzés a beágyazott certtel
```

**Postcondition:** a digest reprodukálható, és az aláírás érvényes a beágyazott
tanúsítvány kulcsával.

A submodule-kollízió lezárva (#38): a `cic-tree-manifest/v2` a Git fáját írja le
közvetlenül, minden bejegyzés mode, típus, OID és path — a gitlink is.

Az átültethetőség lezárva (#44). A v2 **csak a fát** kötötte, és ez mérve is
kihasználható volt: egy A repóban készült aláírt blokk változtatás nélkül átment
egy MÁSIK repó MÁSIK commitján, MÁS üzenettel, mert a két fa azonos volt — a
verifier GO-t adott rá. A `cic-tree-manifest/v3` a fa mellé beköti a **szerzőt,
a committert és az üzenet digestjét**.

Két kézenfekvő mező szándékosan **kimarad**, mindkettő mérés után:

- **remote URL** — környezeti állapot, nem commit-állapot. Ugyanaz a repó SSH-n
  és HTTPS-en más URL-t ad, egy mirror harmadikat, egy remote nélküli másolat
  semmit. Mind legitim, és mind hamis elutasítást kapott volna.
- **szülők** — a hook a commit *előtt* fut, tehát csak a HEAD-et látja.
  `--amend`-nél az új commit szülője a HEAD **szülője**, nem a HEAD: a kötés a
  saját commitján bukott el elsőként. A `git rebase` pedig nem futtatja újra ezt
  a hookot (mérve), csak átviszi a régi blokkot egy új szülő alá. Ebben a
  projektben a rebase minden PR előtt kötelező.

**Amit NEM állít:** a **commit OID-t** a payload nem tartalmazza, és tartalmazni
sem tudja: a `commit-msg` hook akkor fut, amikor a commit még nem létezik. A
szülők, a branch, a tag és a lifecycle-jelentés szintén nincsenek bekötve. A
committer *dátuma* nincs kötve — csak a neve és e-mail címe.

**Fa-kötés és rebase:** egy rebase, ami ténylegesen új alap fölé viszi az ágat,
megváltoztatja a commit fáját is, és így érvényteleníti az aláírását. Ez **nem**
v3-tulajdonság: a v1 és a v2 ugyanígy viselkedik, mert mindkettő a fát köti.

A v1 (tar-alapú) és a v2 aláírások továbbra is ellenőrizhetők; a verifier a
blokkban álló manifest-verzió szerint dönt, ismeretlen verziót pedig elutasít.

**Evidence:** a `verify-signatures.sh` kimenete reason code-okkal, és a
`tools/test-proof-binding.sh` — ami a VALÓDI hookot futtatja valódi
`git commit`-on, és a VALÓDI verifierrel olvassa vissza.

---

## Git a bizalom forrása

Az aláírt commit maga az igazolás (`commit-msg` hook). Az agent a klónból
commitol és pushol a feature branch-re — az review artifact, nem véglegesítés.
Push a `main`-re kizárólag az orchestrátor joga.

**Az orchestrátori review is bizonyítékot termel.** Minden réteg artifactot hagy
(aláírt commit, claim-evidence tábla, reachability output, headSha) — kivéve
régen a review-t, ami egy chat-üzenet volt: aláíratlan, nem reprodukálható, a
session végén elveszett. Ezért kötelező a `jobs/<job-id>/review.md`.

Amihez nem tudsz verifikációs módszert írni, az a „nem igazolt" sorba megy.

---

## Job struktúra

```
jobs/
  index.yaml                  ← auto-generált állapottérkép (tools/update-index.sh)
  .schema/meta.yaml           ← a meta.yaml sémája
  <job-id>/
    input.md                  ← agent prompt (git-tracked)
    meta.yaml                 ← lifecycle + usage (git-tracked)
    review.md                 ← orchestrátori review artifact (kötelező lezárás előtt)
    ref/                      ← referencia anyagok (opcionális, git-tracked)
    output/                   ← az agent leszállítandói
    workspace/                ← gitignored; az agent klónjai élnek itt
```

### meta.yaml

**A mezők forrása [`jobs/.schema/meta.schema.json`](jobs/.schema/meta.schema.json)**
— gépi séma, nem próza. A [`jobs/.schema/meta.yaml`](jobs/.schema/meta.yaml) a
kommentelt példa, és a kapu ellenőrzi, hogy a kulcsai egyeznek a sémáéval.

Ez a dokumentum szándékosan nem sorolja fel őket. Amikor felsorolta, elcsúszott:
a `lease_expires`, a `spec_gate` és a `usage` bekerült a sémába, és a másolat
hallgatott róluk. Egy séma, amit két helyen írunk le, egy helyen elavul — a
kapu ezért ellenőrzi, hogy egyetlen dokumentum se definiálja újra.

A séma **elutasítja** az elgépelt mezőnevet, az érvénytelen `status`- vagy
`spec_gate`-értéket, az üres `agent.model`-t és a hiányzó kötelező blokkot. Egy
job metája a `validate-spec.sh` K10-én keresztül esik át rajta.

### Sub-job lifecycle

Az agent a klónjában hozza létre a sub-job speceket:

```
workspace/<repo>/jobs/<sub-job-id>/input.md + meta.yaml
```

Ezek a feature branch-re kerülnek. Merge után az orchestrátor a live
`jobs/<sub-job-id>/`-ban látja, és futtathatja.

---

## Eszközök

| Parancs | Mit csinál |
|---|---|
| `tools/run-job.sh <job-id> [agent-id]` | **Előbb a spec-kaput futtatja** — NO-GO esetén nem indul. `--skip-spec-gate` megkerüli, de a `meta.yaml` `spec_gate` mezőjébe `skipped` kerül. Klón, `running → awaiting_review`, commit, push. **Nem zár le.** |
| `tools/validate-spec.sh <job-id>` | Gépi kapu indítás előtt (K1, K3, K4, K7, K7b, K8, K9, K10, K11). NO-GO → az agent nem indulhat |
<!-- A /job-validate kézi listája ennél hosszabb: megítélési kérdéseket is tartalmaz, amiket nem dönt el grep. Azok ott vannak felsorolva, kéziként jelölve. -->
| `tools/validate-output.sh <job-id>` | Gépi kapu lezárás előtt (O1–O5) |
| `tools/close-job.sh <job-id>` | **Az egyetlen `awaiting_review → done` átmenet** (C1–C6). `--dry-run` csak ellenőriz |
| `tools/check-stale-jobs.sh` | Kilistázza a `running`-ot állító jobokat, amelyek lease-e lejárt |
| `tools/update-index.sh` | `jobs/index.yaml` újragenerálása |
| `tools/install-claude-hooks.sh [agent-id]` | Agent hookok telepítése; idempotens |
| `tools/init-hooks.sh` | A commit-aláíró git hook bekötése |

### A három gépi kapu

```
spec → validate-spec.sh → agent fut → validate-output.sh → review.md → close-job.sh → done
     (K1,K3,K4,K7,K7b,               (O1–O5)                          (C1–C6)
      K8,K9,K10,K11)
```

Az elv: **amit gép el tud dönteni, azt döntse el a gép.** A drága figyelem a
tartalomra menjen, ne a formára.

Ez nem elmélet: a `validate-output.sh` első éles futása olyan hibát talált, amit
emberi review és merge átengedett.

### Amit a kapuk nem tudnak

A `close-job.sh` C5-e elutasít, ha a futás megkerülte a spec-kaput és a review
ezt nem ismeri el — de a menekülőút maga legális. A `check-stale-jobs.sh`
létezik, de semmi nem futtatja magától. A `meta.yaml` sémája ma template, nincs
mögötte validátor.

Amit egy kapu nem bizonyít, azt ne állítsd róla.

---

## Runnerek — mit futtat a gyár

A factory **nem tudja, milyen agentet futtat**. Egy runner az a csere-darab, ami
tudja: `tools/runners/<név>.sh`, választás a `CIC_AGENT_RUNNER`-rel
(alapértelmezés: `claude`).

A runner környezeti változókból kap mindent, és egy normalizált JSON-t ír —
szerződés: [`docs/RUNNER-CONTRACT.md`](docs/RUNNER-CONTRACT.md), séma:
[`jobs/.schema/runner-result.schema.json`](jobs/.schema/runner-result.schema.json).

| runner | mit futtat |
|---|---|
| `claude` | Claude Code. Minden Claude-specifikus ismeret itt él: CLI-flagek, `CLAUDE_CONFIG_DIR`, a JSON alakja |
| `echo` | semmit — a promptot adja vissza |

Az `echo` nem játék. Két dolgot bizonyít: hogy a szerződés valódi (egy második
implementáció az egyetlen különbség absztrakció és átnevezés között), és hogy a
lifecycle **végigfuttatható** agent, hálózat és költség nélkül. A
`test-run-job-e2e.sh` ezen áll.

**Amit egy runner nem tud megmondani, azt hagyja ki.** A hiányzó mező üresen
marad a `meta.yaml`-ben. Nullát írni oda mérésnek látszana.

---

## Agent auth

```
<agent-config-dir>/<id>/
  .credentials.json       ← symlink a megosztott hitelesítőre
  settings.json           ← izolált config
```

Indítás: `CLAUDE_CONFIG_DIR=<agent-config-dir>/<id> claude --print "..."`

A jelenlegi implementáció ezt `$HOME/.claude-personal/agents/<id>`-ként
származtatja. Ez CIC-alakú path, és egyben az, ami a `run-job.sh`-t
tesztelhetetlenné tenné `HOME`-felülírás nélkül — a fennmaradó kötések listája a
[README](README.md#known-coupling--what-round-two-has-to-break)-ben.
