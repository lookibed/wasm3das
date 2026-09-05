# Handoff для следующей Claude Code сессии

Дата: 2026-09-05. Репо: `/home/andry/wasm3das`, ветка `main`, remote
`github.com/lookibed/wasm3das`. Предыдущая сессия занималась только
развёртыванием инструментов; исходники порта (`source/`, `tests/`) не менялись.

## С чего начать (5 минут)

1. Запускать `claude` строго из корня `/home/andry/wasm3das`: `.mcp.json` и
   LSP-плагин в `.claude/skills/daslang-lsp/` читаются только оттуда и только на
   старте сессии. После любой правки `.mcp.json` или plugin-манифеста нужен
   полный перезапуск; скилы в `.claude/skills/` подхватываются на лету.
2. Убедиться, что видны инструменты `mcp__daslang__*` (43) и
   `mcp__daslang-dap__*` (21). Если `daslang` не поднялся, смотреть
   `/tmp/daslang_mcp_supervisor.log` и `logs/claude-mcp-daslang-child.log`.
3. Smoke без размышлений:
   - `mcp__daslang__compile_check` file=`source/m3_core.das` → `Compilation OK.`
   - `LSP documentSymbol` по `source/m3_env.das` → список функций.
   - Полный чеклист и рецепт пересборки: `notes/claude_code_tooling_setup_2026-09-04.md`.
4. Прочитать `AGENTS.md` целиком: там правила порта, verification gate и
   контракт DAP. `CLAUDE.md` короткий и ссылается туда.

## Карта инструментов

| Что | Где | Зачем |
|---|---|---|
| Pinned компилятор 0.6.4 @ `1524b3bf` | `tmp/daslang-toolchain/bin/daslang` | единственный авторитетный для compile/lint/test |
| MCP `daslang` | `tmp/daslang-toolchain/utils/mcp/mcp_supervisor.py` | компилятор, lint, поиск, тесты |
| LSP | `tmp/daslang-toolchain/utils/lsp/lsp_supervisor.py` | push-диагностика после каждого edit, навигация |
| MCP `daslang-dap` | `tmp/daslang-dap/utils/dap/mcp_bridge.py` + `tmp/daslang-dap/bin/daslang` | пошаговая отладка; бинарь из daScript PR #3937 с фиксами lifecycle |
| ast-grep | `/usr/local/bin/ast-grep` | нужен для `grep_usage`/`outline`; `/usr/bin/sg` это `newgrp` из пакета `login`, не ast-grep |
| Smoke-скрипты | `tools/smoke/mcp_smoke.py <server> '<json calls>'`, `tools/smoke/lsp_smoke.py` | проверка серверов вне Claude |

`tmp/` и `tools/` гитигнорены. `tmp/daslang-dap` это git worktree репо
`/home/andry/daScript` на ветке `pr-3937`; сам `/home/andry/daScript` стоит на
`master`, его бинарь собран без `dasHV` и MCP `main.das` на нём не стартует.
Не трогать `git stash` в этих worktree: стек общий.

## Грабли, на которые уже наступили

- `grep_usage` и `outline` резолвят относительные пути от корня toolchain, а не
  проекта. Передавать абсолютные: `/home/andry/wasm3das/source`. Остальные
  инструменты (`compile_check`, `lint`, `run_test`, `find_symbol`, ...) принимают
  пути относительно корня wasm3das.
- Инструменты daslang не ищут ничего в `/home/andry/daScript`; новее не значит
  правильнее, гейт привязан к pinned-коммиту.
- Перед тем как писать любой инструмент (мост, обёртку, скрипт) для daslang,
  проверить открытые PR в `GaijinEntertainment/daScript`: пользователь ведёт
  там свои тулзы (DAP-мост это PR #3937). Писать с нуля он не просил и был
  против.
- Одновременные сборки двух daScript на этой машине (4 ядра, 7.7 GB) впритык по
  памяти на LTO-линковке. Собирать по одному, `ninja -j4`.
- Фоновые команды Bash с таймаутом >10 минут убиваются вместе с ожиданием;
  запускать сборку в фоне и ждать через `until grep -q BUILD_EXIT log`.
- Claude Code читает `.mcp.json`, а не `.codex/config.toml` и `opencode.json`.
  Разделы AGENTS.md про Codex и пути `/root/...` относятся к другой машине и к
  Codex; на этой машине `/root` недоступен, `.codex/` нет.

## Состояние гейта на 2026-09-05 (после аудита, ветка `audit/repo-hygiene`)

Pinned CLI (`AGENTS.md`, раздел verification, с `DAS_LINT_CONFIG_PATH=.lint_config`):

- compile-only: 26/26 файлов OK.
- dastest: 56 тестов, 56 passed (было 41: два файла тестов не имели `[test]`).
- lint: paranoid 0, perf 0, style 0 issue(s). До ветки было 569 findings;
  83 из них закрыты политикой `.lint_config` (LINT004, LINT012, LINT021,
  STYLE037, STYLE038 — конструкции, дословно повторяющие C), остальные
  исправлены в коде. Без переменной окружения lint показывает 83 finding'а,
  это признак не выставленного `DAS_LINT_CONFIG_PATH`, а не регрессия.
- CI на `main` красный с коммита 3104b5f; ветка `audit/repo-hygiene`
  (7 коммитов поверх `main`) делает его зелёным. Ветка не запушена.

Аудит 2026-09-05 и его выводы: транскрипты убраны из дерева, манифест
согласован с `source/` (статус Draft для env/compile/exec), сессионные разделы
AGENTS.md переехали в `notes/runtime_recovery_context_2026-09.md`, решение по
модели памяти записано в `docs/memory-ownership.md`, `public require`
приведены к include'ам C-заголовков.

## Незакоммиченное

```
.claude/settings.json
.claude/skills/daslang-*/ (кроме daslang-lint и daslang-lsp), daslib-modules/
                                       (тонкие скилы → tmp/daslang-toolchain/skills/*.md)
notes/claude_code_tooling_setup_2026-09-04.md
notes/handoff_claude_code_2026-09-05.md
```

`.mcp.json`, `.lint_config`, `.claude/skills/daslang-lint/SKILL.md` и plugin-манифест
`.claude/skills/daslang-lsp/` уже закоммичены в ветке аудита, потому что несут
политику lint (`DAS_LINT_CONFIG_PATH`). Остальные скилы содержат абсолютные
пути `/home/andry/...` в тексте (formatting, mcp-tools, dap-debugging,
daslib-modules, testing) и заметка setup тоже; перед коммитом заменить на
относительные или оставить незакоммиченными. Решение за пользователем.
Коммиты в `main` напрямую не делать (README: работа через PR). Ветка
`origin/wip/runtime-layer` полностью влита в `main` (squash в `3104b5f`),
удалять её пользователь не просил; на ней остались чекпоинты 7c25b78,
9a2058e, 5fb3c38, на которые ссылается заметка recovery context.

## Что дальше по порту (из CLAUDE.md и PORTING_MANIFEST.md)

Готовы основы: конфигурация, math, LEB128/binary readers, code pages, metadata
функций, начало `m3_bind`, первая стадия `m3_parse`, драфты env/compile/exec.
Открытые темы: teardown/ownership рантайма (см.
`notes/dap_tooling_update_2026-09-04.md` и коммит #3), полный `m3_parse`,
`m3_compile`, `m3_exec`, публичный API, end-to-end `fib32.wasm`. Перед любым
изменением рантайма прогонять `fib32.wasm` через получение результата и
teardown без краша; для пошаговой отладки использовать `daslang-dap` по
контракту из AGENTS.md, не `pkill daslang` и не ручные порты.

Правила порта: сохранять имена, порядок и control flow C-исходника из
`wasm3c/source`, идиомы Daslang только там, где C-конструкция не выражается;
каждое изменение сверять с C построчно и подтверждать pinned гейтом.
