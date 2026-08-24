# Session-napló — a proof profile (#44) menete

`v0.3.0` óta, `core/@v0.3.0` (`bee6ba8`) és `main` (`433156e`) között: **kilenc
mergelt PR**, mind mérésből indult. Ez a napló nem kiadási jegyzet — a
gondolatmenetet rögzíti, amit a `SPEC.md` és a `README.md` már normatívan
tartalmaz. Dátumbélyeg helyett a PR-sorrend a hivatkozási pont.

---

## Kiindulópont

A `v0.3.0` az M1-et zárta le. Két nagy tétel maradt nyitva a roadmapból
(`#45`): **FC-05** (a core Claude-specifikus könyvtár-layoutot ismer) és
**FC-07** (`#44` — a bizonyíték nem köti a commit identitását). Ez a session
mindkettőt megmozdította, a második nagyobb részét lezárta.

---

## FC-05 — az executor-határ (#76–#78)

Három PR, mérés-vezérelt:

- **#76** — mérés: mi maradt Claude-alakú a core-ban a runner-szerződés
  bevezetése után. A session-kezelés volt a fennmaradó rész.
- **#77** — ha a session-forrás nem egyértelmű (több jelölt fájl), a
  `run-job.sh` most megtagadja a találgatást, ahelyett hogy az elsőt venné.
- **#78** — döntés: **B opció** — a job `meta.yaml`-ja mondja meg, hol él az
  agent konfigurációja (`agent.config_dir`), a core nem tételezi fel a
  Claude-féle könyvtárszerkezetet.

FC-05 ezzel nem zárult le teljesen (`#42` továbbra is nyitva egy résznél), de
a legnagyobb Claude-specifikus feltételezés eltűnt.

---

## FC-07 első fele — a gitlink és a transzplantáció (#79–#80)

### #79 — a gitlink-kollízió

A `v1` (tar-alapú) aláírt payload a submodule commitját üres könyvtárként
vitte: két fa, ami CSAK a submodule commitjában tért el, azonos digestet
adott. A `cic-tree-manifest/v2` a Git fáját írja le közvetlenül — minden
bejegyzés mode, típus, OID és path, a gitlink is —, nincs tar-roundtrip, nincs
umask-függés.

### #80 — a mért átültetés, és a v3 manifest

**A mérés:** két repó, azonos fa, különböző commit, különböző üzenet. Az A
repóra készült aláírt blokk változtatás nélkül átment B másik commitján:

```
  A digest = B digest? IGEN
  OK    222618a commit B — MÁS üzenet
verify-signatures: GO (1 rendben)
```

A `v2` csak a fát kötötte. `cic-tree-manifest/v3` a szerzőt, a committert és
az üzenet digestjét is köti.

**Két mezőt implementáltam, majd mérés után kivettem:**

| mező | miért nem |
|---|---|
| remote URL | környezeti állapot, nem commit-állapot — SSH/HTTPS/mirror mind más URL-t ad, mind hamis elutasítás lenne |
| szülők | a hook a commit ELŐTT fut. `--amend`-nél a HEAD nem az új commit szülője — a kötés a **saját commitján bukott el elsőként**. A `git rebase` (mérve) nem futtatja újra a hookot, csak átviszi a régi blokkot új szülő alá — a rebase-before-PR szabály miatt ez minden PR-t ellenőrizhetetlenné tett volna |

Két normalizálás, mindkettő méréssel jött elő, nem olvasással:
`git stripspace --strip-comments` (a szerkesztős commit `#` sorait a git a
hook UTÁN takarítja el), és a záró újsor kezelése (a `MERGE_MSG` nem
újsorral végződik, a `git log %B` igen — enélkül minden merge commit
ellenőrizhetetlen lett volna).

Mutációs mátrix (a végleges, három mezős kötésen): `author`/`committer`
kivéve → 1 FAIL, `message-sha256` kivéve → 3 FAIL, a szülő-kötés
visszatéve → 2 FAIL, visszaállítva → 0 FAIL.

---

## Amit #80 felszínre hozott: két külön hiba

### #82 → PR #83 — a repó nem a saját hookjával írt alá

A megosztott `hooks/commit-msg` **elavult másolat** volt: még a tar-alapú
`v1`, manifest-sor nélkül. A `#38` és a `#28` javítása két kiadás óta nem volt
a lokális trust path-ban.

`tools/check-hook-provenance.sh` — a hatályos hookot a `git rev-parse
--git-path hooks` oldja fel (a `core.hooksPath`-t figyelembe véve, mérve, nem
újraimplementálva), majd három lépcsőben dönt: symlink → GO, bitre azonos
másolat → GO + drift-figyelmeztetés, minden más → **viselkedési próba**
(mindkét hook lefut azonos scratch repón, hamis Vaulttal, a `manifest` és a
`digest` sor összehasonlítva). A tartalom-összehasonlítás elutasítana egy
legitim wrappert — ezért kell a viselkedési próba.

Az `init-hooks.sh` mostantól megtagadja a telepítést, ha a `core.hooksPath`
felülírná, és telepítés után ellenőriz.

A checkerben ugyanaz a hibaosztály volt, amire vadászik: a
`--git-path hooks` relatív utat ad, ha nincs `core.hooksPath`, a próba pedig
máshonnan futott — élesben (abszolút hooksPath) működött, minden
fixture-ön elbukott.

**Nyitott, a user döntése:** a gépi drift a mai napig javítatlan — egy
symlink a megosztott könyvtárban, ami más CIC repókat is érint.

### #81 → PR #84 — a rebase törte az aláírást

Mérve: `git rebase` nem futtatja újra a `commit-msg` hookot, a commit **fája**
viszont megváltozik. Háromcommitos ágon: rebase után **OK: 0, FAIL: 3** — nem
részleges hatás.

Válasz: **újraaláírás**, nem az elavult aláírás elfogadása.
`tools/resign-range.sh` `git rebase --exec`-kel minden commitot amendel a
saját üzenetével, ami újrafuttatja a hookot. A `git_hook_post-rewrite.sh`
helyben szól, ha egy átírás elavult blokkot hagyott.

Két lelet a mutációs mátrixból, nem olvasásból:

- a `post-rewrite` eredetileg csak `rebase`-re szólt — ez **káros** volt: a
  `git commit --amend --no-verify` is kihagyja a hookot, ott is elavul a
  blokk, és az őr pont ezt a figyelmeztetést nyomta volna el.
- **az aláírás nem véd a saját aláírója ellen**: egy csonkító újraaláíró
  eszköz átmegy a verifikáción, mert azt írja alá, amit előállított. Csak
  tartalmi állítás (a törzs és a szerző saját `---`-ja megmaradt-e) fogja meg.

---

## FC-07 folytatása — a release tag (#44, PR #85–#86)

### #85 — a tag-verifikáció valós, sürgető hibája

Mérve: **mind a három létező release tag** (`v0.2.0`, `v0.2.1`, `v0.3.0`)
`NO-GO`-t adott. A `--tag` út minden merge-re elutasított, függetlenül attól,
hoz-e tartalmat — a release folyamat (branch → PR → merge → tag) miatt egy
release tag *mindig* merge commitra mutat.

A `--range` útnak már megvolt a helyes szabály (a merge fája egyezik egy
szülőével → nem hoz tartalmat, a tartalmat a szülő hordozza), csak nem volt
megosztva. `resolve_content_commit()` visszalépked a tartalom nélküli
merge-eken át az első valódi tartalom-hordozó commitig, és **azt**
ellenőrzi. Mind a három release tag most GO.

### #86 — a tag saját aláírása

`cic-tag-manifest/v1` — `tools/sign-release-tag.sh` (git nem ismer pre-tag
hookot, ez egy explicit lépés `git tag -a` helyett). Köti: tag név, célpont
commit OID, tagger (dátum nélkül — szimmetrikus a commit `v3` döntésével),
üzenet digest. NEM köti a tag saját OID-ját — az a blokk hozzáfűzése UTÁN dől
el, önhivatkozás lenne.

A verifier két **független** réteget néz: a mögöttes commit tartalom-kötése
(mindig), és — ha a tag hordozza — a tag saját aláírása. Régi tag e nélkül is
GO, a hiány jelezve, nem hibaként.

**Refaktor a menetben:** a Vault-hívó kód majdnem duplikálódott a hook és az
új eszköz között — pontosan a `#82` hibaosztálya. Kivonva
`tools/lib-vault-sign.sh`-ba. A hook lib-keresése a repó gyökeréhez igazodik
(`git rev-parse --show-toplevel`), nem a hook-fájl saját könyvtárához —
symlinken vagy wrapperen át is a repó saját libjét használja. Öt meglévő
suite kapott ettől regressziót, mindegyiket a teljes futtatás fogta meg, nem
az olvasás.

---

## Számok

| | `v0.3.0` | most |
|---|---|---|
| assertion | 570 | **715** |
| viselkedési suite | 25 | **29** |
| önálló checker | 7 | **8** |

---

## Amit ez a kör a módszerről ismételten megerősített

A korábbi köröké volt a tézis: *egy kapu, ami nem tud pirosat adni,
díszítés.* Ez a kör hozzátette:

> **Egy mutációs mátrix, aminek egy sora zölden marad, azt jelenti, hogy
> valami a lefedetlen.** Nem azt, hogy a kód jó — azt, hogy a teszt nem tudja
> eldönteni.

Ez ötször fordult elő ebben a körben (a `parents` és `committer` mutáció az
első v3-mátrixban, az `introduces=0` mutáció a tag-merge-walk mátrixban, a
retarget-tamper a tag-signing mátrixban, kétszer a check-hook-provenance
lib-refaktor utáni regresszióban). Egyik sem olvasással derült ki — mindegyik
onnan, hogy a mutáció után újra lefuttattam a suite-ot, és megkérdeztem: *ez a
zöld tényleg azt jelenti, amit gondolok?*

---

## Amit a #44-ből ez a kör NEM zárt le

- gépi olvasható verifier-kimenet, stabil exit-kód dokumentáció, test-vector
  csomag
- publikált trust anchor, key-status lista, timestamp-modell
- lifecycle-attesztáció (`cic.job-transition/v1`) — a review/gate/run
  cseréjének kötése, nem csak a commit/tag identitásé

## Amit ez a kör felszínre hozott, de nem zárt le

- **a gépi hook-drift javítatlan** — a `#83`-mal épített ellenőrző kimutatja,
  de a tényleges symlink-csere a megosztott `hooks/`-ban más CIC repókat is
  érint, ezért a maintainer döntése
- egy rebase, ami ténylegesen új alap fölé viszi az ágat, a FÁT is
  megváltoztatja, és ez minden manifest-verzióban (v1/v2/v3) érvényteleníti
  az aláírást — ez nem hiba, dokumentált korlát (`SPEC.md`), de a
  `resign-range.sh` a válasz rá
