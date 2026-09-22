# Dictionary (Tinycast extension)

Offline stand-in for Raycast's built-in **Define Word**. Uses the macOS system dictionary
(`DCSCopyTextDefinition`) and spellchecker (`NSSpellChecker`). Nothing leaves the machine.

## Commands

- **Define Word** (view): type a word, get definitions in a detail pane. Close typos and
  sound-alikes are suggested as you type (edit distance, metaphone, phonetic rewrites, and
  the system word list). Actions: Copy Word (default), Paste Word, Copy Definition (⌘⇧C),
  Open in Dictionary.app (⌘O). Accepts an optional argument.
- Empty search shows **Recent** lookups (recorded on copy / paste / open).
- Search-bar dropdown filters by dictionary source (**All Dictionaries** or one installed
  source). Preference is remembered.

## Supported dictionaries

Only sources that are **installed and enabled** in macOS Dictionary.app can appear. The
extension further limits the dropdown to English, EU-language, and Chinese dictionaries
(Japanese, Korean, Arabic, Hindi, Thai, Turkish, Russian, Hebrew, etc. are hidden).

### English
- New Oxford American Dictionary
- Oxford Dictionary of English
- Oxford American Writer’s Thesaurus / Oxford Thesaurus of English
- Apple Dictionary
- Wikipedia

### Chinese
- 现代汉语规范词典 (and other 汉 / 漢 titles)
- 牛津英汉汉英词典 (Oxford Chinese Dictionary)
- Cantonese–English / 粤 titles when installed

### EU languages
Shown when the matching Dictionary.app source is installed, including:

| Language | Typical Dictionary.app titles |
| --- | --- |
| German | Duden, Oxford German Dictionary |
| French | Multidictionnaire, Oxford-Hachette French Dictionary |
| Spanish | Diccionario Vox, Gran Diccionario Oxford |
| Italian | Dizionario italiano / Oxford Paravia |
| Dutch | Prisma woordenboek Nederlands |
| Portuguese | Dicionário de Português (Oxford) |
| Swedish / Norwegian / Danish / Finnish | NE Ordbok, Norsk Ordbok, and similar |
| Polish, Czech, Slovak, Hungarian | When installed under those names |
| Greek, Irish, Welsh | When installed |
| Catalan, Romanian, Bulgarian, Croatian, Slovenian | When installed |
| Estonian, Latvian, Lithuanian, Maltese, Basque, Galician | When installed |

Exact titles vary by macOS version and which packs you enabled under
**Dictionary → Settings → Dictionaries**. List what this Mac will show (after building):

```sh
./assets/dictd dictionaries
```

## Layout

- `helper/dictd.swift` — Swift CLI:
  `dictd version` · `dictd dictionaries` · `dictd lookup [--dictionary <name>] <text>` ·
  `dictd define [--dictionary <name>] <word>` (JSON on stdout).
- `assets/dictd` — compiled helper (shipped inside the extension; `assets/` is copied by Tinycast).
- `src/define.tsx` — Define Word command.
- `build/` — output of `npm run build`. Folder to install from when developing locally.

## Install in Tinycast

1. Download `tinycast-dictionary-vX.Y.Z.zip` from the
   [latest release](https://github.com/h-dong/tinycast-dictionary/releases/latest).
2. Unzip it.
3. Settings → Extensions → enable extensions → Install → **Add from folder** → pick the
   unzipped `tinycast-dictionary/` folder.

Re-install from a newer release zip when you update.

## Build

Requires **macOS** (Dictionary Services + `swiftc`). Linux can edit sources but cannot produce `assets/dictd`.

```sh
npm install --registry https://registry.npmjs.org
npm run build
```

`npm run build` runs `swiftc` → `assets/dictd`, then `ray build -e dist -o build`
(the `ray` binary comes from `node_modules` via the npm script).

Helper only:

```sh
npm run build:helper
# or: swiftc -O -o assets/dictd helper/dictd.swift
```

Sanity check:

```sh
./assets/dictd version          # → sounds-1
./assets/dictd dictionaries     # JSON list of allowed sources
./assets/dictd lookup fone      # should suggest phone
```

To sideload a local build: Install → **Add from folder** → pick `build/`. Re-add that folder
after every rebuild so Tinycast picks up the new `assets/dictd`.

## Release

Push a version tag to publish a prebuilt zip via GitHub Actions:

```sh
git tag v0.1.0
git push origin v0.1.0
```
