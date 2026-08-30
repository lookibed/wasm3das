# План фаз: от «13/15» к исполнению fib32.wasm

Дата: 2026-08-30. Продолжение `GLM-5.3-Flash.md`. Цель: end-to-end запуск
`wasm3c/test/lang/fib32.wasm` (62 байта, export `fib (i32)→i32`,
fib(25)=75025). Приоритеты владельца: работоспособность → C-шность → стиль.

## Фаза 0 — гигиена (git) — ВЫПОЛНЕНО 2026-08-30

- Фича-ветка `wip/runtime-layer`; checkpoint-коммит состояния GLM-сессии
  (изменённые source/tests + новые черновики env/compile/exec/exception/
  exec_defs) — ничего не теряется.
- Отдельный коммит: правила тулинга в `AGENTS.md`, эта заметка, заметка про
  LSP-override, skill `.claude/skills/daslang`.
- `opencode.json` НЕ коммитится (машинно-локальные абсолютные пути) —
  добавлен в `.gitignore`.
- Рестарт opencode (руками владельца): LSP переходит на pinned-бинарь
  `tmp/daslang-toolchain/bin/daslang` — см.
  `2026-08-30-lsp-toolchain-override.md`. Расхождение уже поймано:
  new-компилятор (`2cae1d92`) ругается на `m3_module.das`, pinned
  (`1524b3bf`) принимает; авторитетен pinned.

## Фаза 1 — зелёная ветка (15/15)

- Удалить `source/m3_env.das:270-300` — дубли `Module_FreeFunctions` /
  `m3_FreeModule` (истина теперь в `m3_module.das:14,24`). `_FreeModule`
  (строка 303) остаётся: это env-визитор ForEachModule, зовёт
  `m3_FreeModule` из модуля.
- Ошибка `m3_parse.das` — та же цепочка require, чинится автоматически.
- Гейт: compile-only source+tests → 15/15 PASS; dastest → 37/37.
- Подтверждённое состояние FAIL'ов ровно два: `m3_env`, `m3_parse`
  (`30341 too many matching`).

## Фаза 2 — вайринг хуков

- Глобалы уже объявлены: `m3_exec.das:49 CompileFunctionHook`,
  `:51 ResizeMemoryHook`.
- В инициализации env (`m3_NewEnvironment` или отдельная `WireHooks`):
  `CompileFunctionHook = @@CompileFunction` (`m3_compile.das`),
  `ResizeMemoryHook = @@ResizeMemory` (`m3_env.das`).
- Проверить guard'ы `m3_exec.das:56-71` (null-sentinel) — в раннере не
  должны срабатывать.

## Фаза 3 — end-to-end раннер

- `tools/run_fib32.das` (dev-скрипт, НЕ `source/` — не часть порта):
  встроенные 62 байта → `m3_NewEnvironment` → `m3_NewRuntime` →
  `m3_ParseModule` → `m3_LoadModule` → `m3_CompileModule` →
  `m3_FindFunction("fib")` → `m3_CallV(25)` → `m3_GetResultsV` → print.
- Checkpoints: fib(2)=1, fib(10)=55, fib(25)=75025.
- Байты проверены по xxd `wasm3c/test/lang/fib32.wasm`.

## Фаза 4 — отладка рантайма (самая длинная, непредсказуемая)

- `m3_compile.das` и `m3_exec.das` исполняются впервые.
- Ожидать: паники `d_m3Assert` (слотовая арифметика), трапы рекурсии
  `op_Call`, чтение результата со стека, границы memory/table.
- Метод: построчная сверка с `wasm3c/source/m3_compile.c` и `m3_exec.h`;
  LSP-диагностика + `daslang_run_script` как контур отладки; при
  необходимости подключить `m3_info.das` (SPrintArg/dump) из AutosendGPT
  Done.

## Фаза 5 — регрессия

- Успех раннера → dastest-тест `tests/test_fib32.das` (тот же пайплайн,
  assert-ы трёх точек).
- Полный гейт: compile-only + 3 lint-профиля + dastest.

## Фаза 6 — бумажки

- `PORTING_MANIFEST.md`: `m3_env`/`m3_compile`/`m3_exec` → **Revision**
  (принимает только code-owner); parse/module пересмотреть после теста;
  добавить строки `m3_exception`/`m3_exec_defs`.
- Журнал сессии в `notes/`, PR в фича-ветке.

## Открытые решения (нужны от владельца)

1. **Lint-гейт**: ~530 замечаний в черновиках. (a) массовые узкие
   `// nolint`; (b) механический фикс PERF020 (~300 лишних same-type
   кастов в exec) + nolint на остальное; (c) отложить до PR-этапа
   (pre-push всё равно валит).
2. **Разбивка PR'ов**: один «runtime layer» или стек
   PR#1 = ф0+ф1 (зелёный минимум), PR#2 = ф2–ф5 (fib32-доказательство),
   PR#3 = lint-washing/manifest.
3. **format_file**: до ревью или после стабилизации рантайма (шум в diff).
