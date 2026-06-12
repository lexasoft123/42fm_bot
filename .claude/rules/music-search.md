---
paths:
  - "models/song.rb"
  - "lib/music_scanner.rb"
  - "lib/database_connector.rb"
  - "lib/commands/radio_search.rb"
---

# Music search / song DB gotchas

Reference: `docs/architecture.md` § Song / § MusicScanner.

| Task | File |
|------|------|
| Music search / song DB | `models/song.rb` + `lib/music_scanner.rb` + `rake music:scan` |

- Radio search uses `Song.search` (multi-stage: FTS5 → Cyrillic→Latin transliteration with k/c variants → prefix truncation → LIKE → Levenshtein editdist); `radio.request` flow is unchanged
- `Song.search` uses FTS5 prefix matching (`word*`) with `unicode61 remove_diacritics 1` tokenizer; Cyrillic input triggers transliteration chain (Stages 1–4); Stage 1 variants include k/c, ts/c, kh/h, and w/v (в→w in translit but v in English proper nouns, e.g. "нирвана"→"nirwana"→"nirvana"); Stage 4 uses a custom `editdist` SQLite function registered by `DatabaseConnector.register_editdist` — catches e.g. "раммштайн"→Rammstein (distance 3)
- `MusicScanner` reads tags via `wahwah` (pure Ruby), falls back to parsing artist/title from filepath; run `bundle exec rake music:scan` to populate/refresh
- `wahwah` gem is pure Ruby — no native dependencies needed for audio tag reading
- `Settings.radio['path']` (music directory root, used by MusicScanner inside the container) and `Settings.radio['source']` (Liquidsoap source name, e.g. `42fm_radio_station`) are in `settings.common.yml`; `Song#absolute_path` joins `host_path` (if set) or `path` + relative `filepath` — set `radio.host_path` in `settings.yml` when Liquidsoap sees a different path than the container (e.g. `/content/music` vs `/home/radio/content/music`)
