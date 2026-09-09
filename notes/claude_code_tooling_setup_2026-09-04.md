# Claude Code: daslang MCP, LSP и DAP для wasm3das

Дата: 2026-09-04. Машина: `/home/andry`, Claude Code 2.1.261.

> Статус на 2026-09-09: раздел «Что развёрнуто» описывает самосборный
> тулчейн `tmp/daslang-toolchain`, от которого проект отказался 2026-09-07
> (`notes/daslang_release_pin_2026-09-07.md`): MCP и LSP теперь работают на
> релизном бандле `tmp/daslang` (`scripts/install_daslang.sh`), DAP-мост
> по-прежнему из `tmp/daslang-dap` с релизным бинарём как отлаживаемым.
> Актуальная конфигурация всегда в `.mcp.json`, `.claude/settings.json` и
> `.claude/skills/daslang-lsp/`; ниже остаётся история и smoke-чеклист.

Конфигурация Claude Code не читает `.codex/config.toml` и `opencode.json`.
Для Claude Code сервера описаны в `.mcp.json` (корень проекта), LSP подключён
как plugin-манифест в `.claude/skills/daslang-lsp/`, разрешения в
`.claude/settings.json`. Все пути относительные к корню проекта.

## Что развёрнуто

| Слой | Путь | Источник |
|---|---|---|
| Pinned toolchain | `tmp/daslang-toolchain/` | daScript `1524b3bf`, собран с `-DDAS_MODULES_INCLUDE=dasHV` (MCP `main.das` требует `dashv`) |
| DAP toolchain | `tmp/daslang-dap/` | git worktree репо `/home/andry/daScript`, ветка `pr-3937` (PR GaijinEntertainment/daScript#3937 "Add MCP bridge for DAP debugging"), содержит C++-фиксы lifecycle/stepping |
| ast-grep | `/usr/local/bin/ast-grep` (копия в `tools/bin/`) | релиз 0.45.3; нужен для `grep_usage`/`outline`. `/usr/bin/sg` — это util-linux, не ast-grep |
| Smoke-скрипты | `tools/smoke/mcp_smoke.py`, `tools/smoke/lsp_smoke.py` | локальные |

Системные пакеты, поставленные для сборки: `libssl-dev`, `ninja-build`.

## Серверы

| Сервер | Команда | Компилятор |
|---|---|---|
| `daslang` (MCP, 43 tools) | `python3 tmp/daslang-toolchain/utils/mcp/mcp_supervisor.py --repo-root .` c `DASLANG_MCP_BIN=tmp/daslang-toolchain/bin/daslang` | pinned |
| `daslang-lsp` (LSP plugin) | `python3 tmp/daslang-toolchain/utils/lsp/lsp_supervisor.py`, `initializationOptions.compiler = tmp/daslang-toolchain/bin/daslang`, `project_root = .` | pinned |
| `daslang-dap` (MCP, 21 tools) | `python3 tmp/daslang-dap/utils/dap/mcp_bridge.py --repo-root . --executable tmp/daslang-dap/bin/daslang` | PR #3937 |

`project_root = .` в LSP нужен, чтобы supervisor не выдавал CROSS-TREE
diagnostic: бинарь и исходники лежат в разных git-деревьях.

## Особенности использования MCP `daslang` из wasm3das

- `compile_check`, `lint`, `run_test` принимают пути относительно корня
  проекта (cwd дочернего daslang = корень wasm3das).
- `grep_usage` и `outline` резолвят относительные пути от корня toolchain,
  поэтому им нужно передавать абсолютные пути (`/home/andry/wasm3das/source`).
- Supervisor спавнит дочерний daslang лениво при первом `tools/*` вызове.

## Проверено

- MCP `daslang`: `list_modules`, `compile_check source/m3_core.das` → `Compilation OK.`,
  `lint`, `grep_usage`, `outline`, `run_test tests`.
- LSP: initialize c полным набором capabilities, `publishDiagnostics` (0 для
  `m3_core.das`), `documentSymbol` (134 символа).
- DAP: `utils/dap/test_mcp_bridge.py` и `DAS_TEST_STEPPING=1 …` проходят;
  smoke `debug_launch(_fixture.das) → debug_threads → debug_configuration_done
  → debug_wait_event(terminated) → debug_disconnect` через `.mcp.json`.
- Pinned CLI gate: compile-only 26/26, dastest 41/41. Lint-профили выдают
  138/397/34 issue(s) при 0 error(s) — состояние исходников до этой настройки.

## Скилы Claude Code

`.claude/skills/daslang/` — копия `skills/daslang` из pinned toolchain (языковой
справочник). Остальные скилы — тонкие `SKILL.md`, которые указывают на актуальные
для pinned-версии документы в `tmp/daslang-toolchain/skills/` (без копирования,
чтобы не расходиться с компилятором): `daslang-formatting`, `daslang-testing`,
`daslang-mcp-tools`, `daslang-lint`, `daslib-modules`, `daslang-macros`,
`daslang-leak-detection`, `daslang-dap-debugging` (последний ссылается на
`tmp/daslang-dap/utils/dap/README.md` и `doc/source/reference/utils/dap.rst`).
`daslang-lsp` — не скил, а plugin-манифест LSP-сервера. В daScript аналогичные
инструкции живут в `skills/*.md` и подключаются через таблицу в `CLAUDE.md`.

## Восстановление после `rm -rf tmp/`

```sh
git clone --filter=blob:none https://github.com/GaijinEntertainment/daScript.git tmp/daslang-toolchain
git -C tmp/daslang-toolchain checkout 1524b3bf62e7decbfe530dc5f2e794b296fa1e68
cmake -S tmp/daslang-toolchain -B tmp/daslang-toolchain/build -G Ninja -DCMAKE_BUILD_TYPE=Release \
  -DDAS_MODULES_INCLUDE=dasHV -DDAS_TESTS_DISABLED=ON -DDAS_TUTORIAL_DISABLED=ON -DDAS_AOT_EXAMPLES_DISABLED=ON
ninja -C tmp/daslang-toolchain/build daslang dasModuleHV tree_sitter_daslang

git -C /home/andry/daScript fetch origin pull/3937/head:pr-3937
git -C /home/andry/daScript worktree add "$PWD/tmp/daslang-dap" pr-3937
cmake -S tmp/daslang-dap -B tmp/daslang-dap/build -G Ninja -DCMAKE_BUILD_TYPE=Release \
  -DDAS_MODULES_INCLUDE= -DDAS_TESTS_DISABLED=ON -DDAS_TUTORIAL_DISABLED=ON -DDAS_AOT_EXAMPLES_DISABLED=ON
ninja -C tmp/daslang-dap/build daslang
```

После правки `.mcp.json` или plugin-манифеста нужен полный перезапуск
`claude` из корня проекта: схемы MCP и LSP-плагины читаются только на старте.
