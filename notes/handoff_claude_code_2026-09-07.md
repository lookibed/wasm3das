# Handoff для следующей Claude Code сессии

Дата: 2026-09-07. Репо: `/home/andry/wasm3das`, remote
`github.com/lookibed/wasm3das`. Предыдущие handoff'ы (2026-09-05,
2026-09-06) описывают инструменты и путь до релизов v0.1.0/v0.2.0; этот
описывает, что добавилось после них и как теперь устроен pipeline.

## Состояние на конец сессии

- `main` = `769b4e1` (PR #28 влит: наборы фикстур из релиза 0.1.0).
- **Открыт PR #29** (ветка `perf/native-aot-trampoline`, 6 коммитов, gate
  зелёный, вливать владельцу). Он содержит всё ниже; пока не влит, `main`
  не знает ни про native, ни про `tests/integration`.
- Релизы v0.1.0 и v0.2.0 с тремя бандлами (Linux x86_64/arm64, Windows)
  собраны интерпретатором daslang; нативная сборка в релиз не добавлена.

## Что сделано в PR #29

1. **RunLoop-диспетчер** (`source/m3_exec_defs.das`,
   `notes/exec_trampoline_design.md`): вместо C `M3_MUSTTAIL` операции
   получают пять регистров интерпретатора по ссылке и возвращают сентинел
   `m3Ret_nextOp` в цикл `RunLoop`; вложенные кадры только на wasm-вызов.
   Сентинел обязан быть `var`, а не `let` (константа сворачивается, JIT
   держит свою копию, сравнение указателей ломается).
2. **Нативная AOT-сборка** (`scripts/build_native.sh` →
   `tmp/native/bin/wasm3das`, обёртка `scripts/wasm3-native`, хост
   `native/wasm3das_main.cpp`, `notes/native_aot_status.md`). Каждый модуль
   порта компилируется daslang-AOT в C++ и линкуется со статическим
   `libDaScript` пинованного тулчейна (нужна цель `daslang_static`). Три
   отличия AOT-лоуринга от интерпретатора исправлены в daslang-исходниках
   порта, никогда в сгенерированном C++: enum чужого модуля объявляется
   только там, где используется его значение (`m3_TaggedValueNone` в
   `m3_types.das`); `array<void const?>` не имеет инстанцированных
   builtin'ов (везде `array<void?>`); `reinterpret<указатель>(функция)`
   даёт адрес значения, поэтому `EmitWord`, `FindAndLinkFunction` и
   `op_Compile` идут через `u64`. Нативный бинарь: спека 17863/17863,
   WASI `--fast` 7/7, fib(35) 3.5 с исполнения против 0.65 с у C и 69 с у
   интерпретатора. Старт 2 с (компиляция `.das`) остаётся и у native;
   убирает его только standalone-контекст (`-ctx`), который на пинованном
   0.6.4 падает в `aot_standalone.das` на глобальном `let`.
3. **Бенчмарки**: `scripts/bench.sh` (fib32 на wasmtime, C wasm3,
   интерпретатор, `-jit`, native; `notes/benchmark_2026-09-07.md`) и
   `tests/manual/run_fixtures.py` (98 проверок реальных модулей, отчёт
   `tests/manual/fixture_report.md` в форме владельца: полное время от
   старта процесса, ✗ в ячейке при расхождении с baseline, итоги и
   отношения к C). Замеры делать на тихой машине: ничего тяжёлого
   параллельно, включая gate.
4. **JIT (dasLLVM)**: собран в worktree `tmp/daslang-jit` (тот же коммит
   1524b3bf, `-DDAS_LLVM_DISABLED=OFF`, prebuilt LLVM 22 качается сам);
   `WASM3DAS_JIT=1 DASLANG=tmp/daslang-jit/bin/daslang scripts/wasm3 ...`.
   Считает неверно: `call_indirect` → `[trap] indirect call type mismatch`,
   h264 → `undefined element`, тихие неверные значения, зацикливание на
   builder-фикстурах. Два найденных бага dasLLVM лежат патчем в
   `notes/daslang_jit_fixes_2026-09-07.patch` для upstream PR. Колонка jit в
   отчёте это baseline, а не рабочий режим.
5. **Раскладка `tests/`**: `tests/integration/` (dastest, гоняет gate и
   CI), `tests/manual/` (фикстуры, харнесс, отчёт; gate их не трогает),
   `tests/host_test/` (Daslang-аналоги `wasm3c/host_test`, компилируются и
   линтуются gate'ом, не dastest). `host_test/` в корне больше нет.
   Тулы в `tools/` (гитигнор): `tools/bin/wasmtime` 48.0.1 и
   `tools/bin/wasm3` (C, собран из `wasm3c/` с `-DBUILD_WASI=simple`).

## Pipeline: что и в каком порядке

1. Правки только Edit/Write; ветка от `main`; `scripts/gate.sh` зелёный
   (compile, три lint-профиля, dastest `tests/integration`, инварианты).
   Пуш прогоняет тот же gate hook'ом (`--no-verify` заблокирован).
2. Для исполнительных правок дополнительно: `run-spec-test.py` через
   `scripts/wasm3 --repl` (рецепт в `notes/spec_test_status.md`),
   `run-wasi-test.py --fast` (`notes/wasi_test_status.md`); для AOT-правок
   пересобрать native (`scripts/build_native.sh`, ~5 мин) и прогнать те же
   два драйвера через `scripts/wasm3-native`.
3. Замеры: `scripts/bench.sh` и `python3 tests/manual/run_fixtures.py`
   (~7 мин без jit, ~30 мин с jit); отчёт коммитить вместе с изменением.
4. PR один на единицу работы, squash-merge, ветки удаляются; описание PR
   без служебных хвостов. Merge за владельцем, если он не сказал иначе.
5. Релиз: тег `vX.Y.Z` + `gh release create` → `release.yml` собирает три
   бандла; повторный прогон `gh workflow run release.yml --ref main -f tag=...`.

## Грабли этой сессии

- `pgrep -f`/`pkill -f` с шаблоном из собственной командной строки убивает
  сам shell (exit 144); якорить шаблон началом строки (`^/path/bin`) или
  исключать `$$`.
- Харнесс с колонкой native зависал под `subprocess.run` (нативный бинарь
  не отдавал pipe); в таблице native сейчас нет, причина не разобрана.
- `Result:` идёт в stderr в обоих режимах приложения; захват вывода всегда
  `2>&1`.
- Тесты, пишущие в `tmp/`, обязаны `mkdir("tmp")`: в CI каталога нет.
- Замер на "чистой машине" ломает любой параллельный gate/сборка.

## Что дальше

1. Влить PR #29; затем решить, ставить ли native в релизные бандлы и в
   колонку отчёта вместо интерпретатора.
2. Разобрать зависание native-колонки под харнессом.
3. Standalone-контекст (ноль старта): починить/обойти падение
   `aot_standalone.das` на глобальном `let`, затем `-ctx`.
4. Upstream PR с патчем JIT; после него перемерить jit-колонку.
5. Полный WASI-список через native, `m3_info`, трейсер, code-owner review
   слоёв со статусом Revision.
