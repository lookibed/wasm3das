# Handoff для следующей Claude Code сессии

Дата: 2026-09-06. Репо: `/home/andry/wasm3das`, ветка `main`, remote
`github.com/lookibed/wasm3das`. За день порт прошёл путь от «fib32 считает»
до двух релизов с бинарными сборками; ниже состояние и что осталось.

## Состояние

- **Релизы**: `v0.1.0` (core spec suite зелёный) и `v0.2.0` (WASI), оба с
  тремя бандлами (`linux-x86_64`, `linux-arm64`, `windows-x64`) и sha256.
  Бандл собирает `.github/workflows/release.yml` из пинованного daslang
  (`daslang_static`, lean-конфигурация, clang на Linux, MSVC на Windows) плюс
  `scripts/make_release_bundle.sh`; каждый бандл проходит smoke на своём
  раннере, x86_64 дополнительно проверен скачиванием и запуском fib32, REPL,
  `mal.wasm` и `simple/test.wasm`.
- **Спека**: оригинальный `wasm3c/test/run-spec-test.py` через
  `scripts/wasm3 --repl`: 17863/17863 (opam-1.1.1) и 17526/17526 (v1.1),
  0 крэшей (`notes/spec_test_status.md`).
- **WASI**: оригинальный `wasm3c/test/run-wasi-test.py`: `--fast` 7/7 и
  полный список 12/12 (включая STREAM, CoreMark, self-hosting
  `wasm3-fib.wasm` и Brotli на полном `alice29.txt`), 0 крэшей, вывод
  побайтно точный (`notes/wasi_test_status.md`). Полный список идёт ~80
  минут.
- Gate (`scripts/gate.sh`): compile, три lint-профиля на 42 файлах, 123
  теста, инварианты. CI = тот же скрипт.

## Как запускать оригинальные тесты

Оба драйвера резолвят фикстуры относительно своей директории, поэтому
рабочая раскладка живёт в гитигнорённом `tmp/` (симлинки на скрипт,
`wasm3c/extra` и фикстуры): рецепты в `notes/spec_test_status.md` и
`notes/wasi_test_status.md`. Драйвер WASI запускать через `python3 -u`,
иначе вердикты сидят в буфере до конца прогона.

## Грабли этой сессии

- `Result:` в `app/wasm3.das` печатается в stderr в обоих режимах (как в C
  `main.c`); любой захват вывода должен объединять потоки (`2>&1`). Четыре
  падения release-workflow подряд были из-за этого.
- `grep -q` на выходе REPL под `pipefail` даёт SIGPIPE: сначала захватывать
  в переменную, потом grep.
- В Git bash на Windows `[[ -f daslang_static ]]` истинно и для
  `daslang_static.exe`; пробовать кандидаты с `.exe` первыми, `editbin`
  давать нативный путь через `cygpath -w` и опции в форме `-STACK:`.
- Daslang резервирует идентификаторы с `__`: константы `wasi_core.h`
  пишутся `WASI_X` / `wasi_x_t`.
- Вызов void-функции, единственный эффект которой запись по raw-указателю,
  оптимизатор может выбросить; такой хелпер нужно помечать `[sideeffects]`.
- Фикстуры `wasm3c/test/wasi/brotli/alice29*.txt` были LF, а дайджесты
  драйвера посчитаны по CRLF-оригиналу; восстановлены из upstream, и
  `.gitattributes` держит `wasm3c/test/**` как `-text`.
- Ветка с несколькими коммитами: если владелец вольёт PR до пуша второго
  коммита, ветка авто-удаляется и коммит остаётся локальным; переносить
  cherry-pick на новую ветку от `main`.

## Что дальше

1. Второй прогон спеки `--spec=v1.1` и полного WASI-списка на бандлах
   arm64/Windows (пока проверены только smoke на раннерах и x86_64 локально).
2. `m3_info.c` и трейсер не начаты; `m3_api_uvwasi`/`meta_wasi` исключены.
3. Все слои после `m3_module` стоят в статусе Revision: нужен code-owner
   review до перевода в Accepted (`PORTING_MANIFEST.md`).
4. Производительность: интерпретатор в интерпретаторе, ~100x медленнее C;
   `M3_MUSTTAIL` не воспроизведён, глубокая рекурсия держится на большом
   стеке (`options stack` в приложении, `ulimit -s` в обёртке, `editbin` на
   Windows).
