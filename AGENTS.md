# AGENTS.md — AdaChess

Two **independent** chess engines live in this repo and share only documentation.
Know which one you are editing before you start.

| | MB (mailbox, original) | BB (bitboard, from scratch) |
|---|---|---|
| Sources | `src/` (packages `Chess.*`) | `src_bb/` (packages `BBChess.*` + C shim) |
| Project file | `adachess.gpr` | `adachess_bb.gpr` |
| Binary | `./adachess` (repo root) | `./bin_bb/adachess_bb` |
| Role | Reference / perft oracle | Active development target |

`DEVELOPMENT.md` is the authoritative engineering log (in French, ~640 lines); it
uses **MB** and **BB** for the two engines throughout. `CHANGELOG.md` covers BB.
`README.md` is the upstream MB readme and is partly stale (v4.0/Windows).

## Build

```bash
gprbuild -P adachess.gpr    -XMode=release   # -> ./adachess
gprbuild -P adachess_bb.gpr -XMode=release   # -> ./bin_bb/adachess_bb
```

- Toolchain: GNAT Ada 2012 + `gprbuild`. MB modes: `release` (default), `speed`,
  `debug`, `profile`. BB modes: `release` (default), `debug`.
- BB release compiles with `-mpopcnt -mbmi -mbmi2` and uses `_pext_u64` (PEXT) for
  sliding attacks — it requires a CPU with BMI2/POPCNT.
- **Gotcha**: after any `-pg`/`profile` build, `rm -rf obj_bb` before rebuilding
  normally. gprbuild reuses instrumented objects and skews `--bench` by ~3x.

## Test & verify (no test framework, no CI)

```bash
./bin_bb/adachess_bb --selftest    # perft 1-5, Zobrist, packed moves, FEN
                                   # validation, search, repetition, SEE,
                                   # Polyglot key. Exit 0.
./bin_bb/adachess_bb --bench 9     # 8 fixed positions at depth 9 -> nodes/time/knps
```

- **Golden rule**: any movegen/search/eval change must keep `--selftest` green
  (perft counts must not change) and keep evaluation symmetric.
- Symmetry is tested on `Static`: startpos = 0 and mirror ⇒ `-Static`.
  `Evaluate` itself is not antisymmetric because it adds a tempo bonus.
- MB has no equivalent self-test command; BB's perft is validated against MB and
  known perft values.

## Benchmarking / matches (needs `cutechess-cli`)

```bash
scripts/ab.sh 1+0.1 20 7          # reference vs current HEAD
scripts/vs_gnuchess.sh 30+1 12 7  # vs GNU Chess (UCI)
```

- `ab.sh` compares against `~/bin/adachess_bb` (the frozen `bb-1.0` reference).
  Rebuild BB first; it uses `bin_bb/adachess_bb` as HEAD.
- `vs_gnuchess.sh` needs the wrapper `~/bin/gnuchess_uci.sh` (GNU Chess must run
  as UCI; its XBoard mode is incomplete). Both paths are machine-local, not in-repo.

## BB command-line modes

`--selftest`, `--bench [depth]` (default 8), `--threads N` (Lazy SMP, max 16),
`--book <file>`, `--syzygy <dir>`, `--dump-params`, `--eval-fens <file>`,
`--params <file>`. `--params`/`--threads` apply to every mode; `--book`/`--syzygy`
only to the playing modes (not probed by `--selftest`/`--bench`/`--eval-fens`).

BB speaks **both** XBoard and UCI (protocol selected by the `uci` command).
`go` exists in both protocols. UCI search is synchronous — `stop` does not
interrupt an in-progress `go`.

## Conventions & gotchas

- Ada unit ↔ file name: `BBChess.Search.PV` → `bbchess-search-pv.adb`;
  `Chess.Engine` → `chess-engine.adb`. MB uses the `chess-*` prefix, BB `bbchess-*`.
- Generated/ignored (never commit): `obj/`, `obj_bb/`, `bin_bb/`, `adachess`,
  `*.o`, `*.ali`, `*.pgn`, `*.txt`. The root `adachess` and `bin_bb/adachess_bb`
  are build outputs.
- `scripts/tune.py` (Texel tuner) requires `python-chess`; `scripts/gen_dataset.py`
  builds `FEN;result` datasets from PGN. Tuning was a **negative result** — default
  eval parameters were kept on purpose (see `DEVELOPMENT.md` § 7sexies).
- Opening book: Polyglot `.bin` (`BBChess.Polyglot`), probed before the search
  (16-ply limit, legal-move checked). Fetch a CC0 book with
  `scripts/fetch_book.sh` → `books/book.bin` (gitignored). Override with
  `--book <file>` or UCI `setoption name BookFile value <path>`. Polyglot keys
  are cross-checked in `--selftest`.
- Endgame tablebases: Syzygy via **vendored Fathom** (`src_bb/fathom/`, MIT).
  Enable with `--syzygy <dir>` or UCI `SyzygyPath`; inert without `.rtbw`/`.rtbz`
  files. WDL is probed in the search (no castling rights); no DTZ yet.
- Log notable engine changes in `DEVELOPMENT.md` (French, sectioned) and
  `CHANGELOG.md`, matching the existing style.
- The search Phase 0/1, the eval `threats` term and the Polyglot opening book
  (`DEVELOPMENT.md` §9-11) were developed with the AI agent **Sisyphus**
  (OhMyOpenCode) under **OpenCode**, model `deepseek/deepseek-v4-flash`.
