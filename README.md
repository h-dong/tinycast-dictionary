# Dictionary (Tinycast extension)

Offline stand-in for Raycast's built-in **Define Word**. Uses the macOS system dictionary
(`DCSCopyTextDefinition`) and spellchecker (`NSSpellChecker`). Nothing leaves the machine.

## Commands

- **Define Word** (view): type a word, get definitions in a detail pane. Misspellings show a
  "Did you mean" list built from spellchecker guesses and completions. Actions: Copy Word
  (default), Paste Word, Copy Definition (⌘⇧C), Open in Dictionary.app (⌘O). Accepts an optional
  argument.

## Layout

- `helper/dictd.swift` — Swift CLI. `dictd lookup <text>`, `dictd define <word>`, all print JSON.
- `assets/dictd` — compiled helper (shipped inside the extension; `assets/` is copied by Tinycast).
- `src/define.tsx` — Define Word command.
- `build/` — output of `ray build -e dist -o build`. This is the folder to give Tinycast.

## Build

```sh
swiftc -O -o assets/dictd helper/dictd.swift
npm install --registry https://registry.npmjs.org
npm run build
```

## Install in Tinycast

Settings → Extensions → enable extensions → Install → **Add from folder** → pick `build/`.
Re-run the install after each rebuild.
