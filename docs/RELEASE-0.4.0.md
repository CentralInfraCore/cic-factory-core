# cic-factory-core v0.4.0

A `v0.2.0` óta tézisből most az utolsó vált gyakorlattá: a `v0.3.0` saját
"amit NEM garantál" listája két tételt nevezett meg névvel — a #44-et és a
#38-at. Ez a kiadás mindkettőt zárja, és felszínre hozott két olyan hibát,
amit egyik sem mért volna, ha nem épül rá.

Tag: `core/@v0.4.0` — 9 commit a `core/@v0.3.0` óta.

---

## Miért minor bump

**Nincs kényszerített migráció.** A `v0.3.0` sémabővítést és
viselkedésváltást hozott — ez a kör additív: régi aláírások és régi release
tagek változatlanul verifikálnak, semmi meglévő nem törik.

Amiért mégsem patch: **három új, opcionális eszköz** kerül az adoptáló repók
kezébe — `sign-release-tag.sh`, `resign-range.sh`, és a `post-rewrite` hook —,
és **négy új gate lépés** fut le automatikusan a következő átvételnél. Ez
capability, nem csak defekt-javítás.

---

## A signature-t köti a commit KONTEXTUSA is, nem csak a fája

Mérve: az `A` repóra készült aláírt blokk változtatás nélkül átment egy
MÁSIK repó MÁSIK commitján, MÁS üzenettel, mert a `v2` manifest csak a fát
kötötte, és a két fa azonos volt.

```
  A digest = B digest? IGEN
  OK    222618a commit B — MÁS üzenet
verify-signatures: GO (1 rendben)
```

`cic-tree-manifest/v3` a szerzőt, a committert és az üzenet digestjét is
köti. A remote URL és a szülők szándékosan KIMARADTAK — mindkettőt mérés
után vettük ki: a remote URL környezeti állapot (SSH/HTTPS/mirror mind más),
a szülő-kötés pedig a **saját commitján bukott el elsőként**, mert a hook a
commit előtt fut, és a `git rebase` (mérve) nem futtatja újra.

---

## Amit ez felszínre hozott

**A repó nem a saját hookjával írt alá.** A megosztott `hooks/commit-msg`
elavult másolat volt — még a tar-alapú `v1`, manifest-sor nélkül. A `#38` és
a `#28` javítása két kiadás óta nem volt a lokális trust path-ban, és semmi
nem szólt. `tools/check-hook-provenance.sh` egy viselkedési próbával dönti
el, a hatályos hook a kiadott signer-e — a tartalom-összehasonlítás
elutasítana egy legitim wrappert, ezért kell a próba. Az `init-hooks.sh`
mostantól megtagadja a telepítést, ha a `core.hooksPath` felülírná.

**A rebase törte az aláírást.** A `git rebase` nem futtatja újra a hookot, a
commit fája viszont megváltozik. Háromcommitos ágon mérve: rebase után **OK:
0, FAIL: 3** — nem részleges hatás. `tools/resign-range.sh` `git rebase
--exec`-kel újraaláír; a `post-rewrite` hook helyben szól, ha egy átírás
elavult blokkot hagyott.

---

## A release tag valós, sürgető hibája

Mérve: **mind a három addig kiadott release tag** (`v0.2.0`, `v0.2.1`,
`v0.3.0`) `NO-GO`-t adott. A `--tag` út minden merge commitra mutató tag-et
elutasított, függetlenül attól, hoz-e tartalmat — a release folyamat
(branch → PR → merge → tag) miatt egy release tag *mindig* merge commitra
mutat.

```
core/@v0.2.0   FAIL  merge commitra mutat — tedd az aláírt szülőre
core/@v0.2.1   FAIL  merge commitra mutat — tedd az aláírt szülőre
core/@v0.3.0   FAIL  merge commitra mutat — tedd az aláírt szülőre
```

A `--range` útnak már megvolt a helyes szabály — a merge fája egyezik egy
szülőével → nem hoz tartalmat, a tartalmat a szülő hordozza —, csak nem volt
megosztva a `--tag` úttal. `resolve_content_commit()` visszalépked a
tartalom nélküli merge-eken át, amíg egy valódi tartalom-hordozó commithoz
nem ér. Mind a három tag most GO — **ez a tag, `core/@v0.4.0`, is így lett
ellenőrizve.**

---

## A release tag saját aláírása — `cic-tag-manifest/v1`

Ez a tag `tools/sign-release-tag.sh`-val készült — ezért az **első**, ami a
tag szintjén is Vault-tal aláírt.

```
$ bash tools/sign-release-tag.sh core/@v0.4.0 <merge-commit> docs/RELEASE-0.4.0.md
$ bash tools/verify-signatures.sh --tag core/@v0.4.0
  OK    <merge-commit összefoglaló>
        a tartalom nélküli merge-eken át: <release-commit összefoglaló>
  OK    a tag objektum maga is aláírva (cic-tag-manifest/v1)
verify-signatures: GO (1 rendben)
```

A git nem ismer pre-tag hookot — ez egy explicit lépés `git tag -a` helyett.
Köti: a tag nevét, a célpont commit OID-ját, a taggert (dátum nélkül —
szimmetrikus a commit `v3` döntésével) és az üzenet digestjét. NEM köti a tag
saját OID-ját — az a blokk hozzáfűzése UTÁN dől el, önhivatkozás lenne.

A verifier két **független** réteget néz ezután minden tagen: a mögöttes
commit tartalom-kötése (mindig), és — ha a tag hordozza — a tag saját
aláírása. A korábbi három tag e nélkül is GO-t ad; a hiány jelezve van, nem
hibaként.

---

## Számok

| | `v0.3.0` | `v0.4.0` |
|---|---|---|
| assertion | 570 | **715** |
| viselkedési suite | 25 | **29** |
| önálló checker | 7 | **8** |

---

## Amit NEM garantál

- **A gépi hook-drift javítatlan.** A `check-hook-provenance.sh` kimutatja,
  de a tényleges symlink-csere a megosztott `hooks/`-ban más CIC repókat is
  érint — a maintainer döntése.
  ([#82](https://github.com/CentralInfraCore/cic-factory-core/issues/82))
- **Egy rebase, ami ténylegesen új alap fölé viszi az ágat, a FÁT is
  megváltoztatja** — ez minden manifest-verzióban (v1/v2/v3) érvényteleníti
  az aláírást. Nem hiba, dokumentált korlát; a `resign-range.sh` a válasz rá.
- **Gépi olvasható verifier-kimenet nincs.** A `verify-signatures.sh` szöveges
  kimenetet ad, nincs `--json`, nincs stabil, dokumentált exit-kód lista, és
  nincs test-vector csomag külső fogyasztóknak.
  ([#44](https://github.com/CentralInfraCore/cic-factory-core/issues/44))
- **Nincs publikált trust anchor, key-status lista, sem timestamp-modell.**
  A tanúsítványnak nincs code-signing EKU-ja, nincs AIA-ja, nincs CRL-je,
  nincs OCSP-je — külső fogyasztó a kulcs-egyezést tudja ellenőrizni, a
  kulcs-eredetet nem. ([#44](https://github.com/CentralInfraCore/cic-factory-core/issues/44))
- **A lifecycle-attesztáció (`cic.job-transition/v1`) érintetlen.** A review,
  a gate és a run cseréjét semmi nem köti — csak a commit és a tag
  identitását. ([#44](https://github.com/CentralInfraCore/cic-factory-core/issues/44))
- **Az executor-határ félkész.** A session-kezelés a legnagyobb maradék
  Claude-specifikus feltételezés.
  ([#42](https://github.com/CentralInfraCore/cic-factory-core/issues/42))
- **Az agent-hookok tanácsadók.** A valódi határ a remote-oldali elfogadás.
  ([#10](https://github.com/CentralInfraCore/cic-factory-core/issues/10))

---

## Migráció

Nincs kötelező lépés. Aki az új képességeket akarja:

### 1. A `post-rewrite` hook telepítése

```
bash tools/init-hooks.sh
```

Ha `core.hooksPath` egy megosztott könyvtárra mutat, a script megtagadja a
telepítést, és megmondja, mi a két kiút.

### 2. Elavult, rebase-elt commitok újraaláírása

```
bash tools/resign-range.sh <upstream>
```

### 3. Release tag aláírása

```
bash tools/sign-release-tag.sh <tag-név> <target-commit> <üzenet-fájl>
```

---

## Amit a session-napló részletesebben rögzít

A mérés → döntés lánc — mit próbáltunk ki és vetettünk el, mit fogott meg a
mutációs mátrix — a
[`docs/SESSION-2026-08-proof-profile.md`](SESSION-2026-08-proof-profile.md)-ben
él. Ott a visszatérő tanulság is: egy mutációs mátrix-sor, ami zölden marad,
azt jelenti, hogy valami lefedetlen — nem azt, hogy a kód jó. Ez a kör ötször
mutatta meg, egyik sem olvasással derült ki.
