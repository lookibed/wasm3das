# Подключение нативного LSP и проектный override компилятора

Дата: 2026-08-30. Сессия qwen3.8-flash (opencode).

## Что было

Daslang LSP уже был зарегистрирован нативно (не хуком) в глобальном
`~/.config/opencode/opencode.json`:

```jsonc
"lsp": {
  "daslang": {
    "command": ["python3", "/root/daScript/utils/lsp/lsp_supervisor.py"],
    "extensions": [".das"],
    "initialization": { "compiler": "/root/daScript/bin/daslang" }
  }
}
```

Проверка живости (ручной stdio-хендшейк initialize → didOpen m3_core.das):
initialize отвечает полным набором capabilities (definition, hover, references,
document/workspace symbols, implementation, call hierarchy), publishDiagnostics
приходит. То есть LSP в сессии работал и до правки.

## Проблема

LSP-диагностика шла от бинаря `/root/daScript/bin/daslang` (HEAD `2cae1d92`).
Верификационный гейт репо (AGENTS.md, `daslang-quality.yml`, pre-push)
зафиксирован за toolchain 0.6.4 commit `1524b3bf…`, лежащим в
`tmp/daslang-toolchain/`. Расхождение версий = риск фантомных или пропущенных
диагностик относительно CI.

## Решение: проектный override

Создан `/root/wasm3das/opencode.json`. Конфиги opencode мержатся
глубоко (project поверх global), поэтому переопределён только
`lsp.daslang.initialization.compiler`:

```jsonc
{
  "$schema": "https://opencode.ai/config.json",
  "lsp": {
    "daslang": {
      "command": ["python3", "/root/daScript/utils/lsp/lsp_supervisor.py"],
      "extensions": [".das"],
      "initialization": { "compiler": "/root/wasm3das/tmp/daslang-toolchain/bin/daslang" }
    }
  }
}
```

- `initialization.compiler` — высший приоритет в порядке поиска компилятора
  (`initializationOptions.compiler` → `$DASLANG_LSP_COMPILER` → layout-пути
  репо → `PATH`), пути абсолютизатором приводятся к workspace.
- Supervisor (`utils/lsp/lsp_supervisor.py`) остаётся из `/root/daScript` —
  он не знает языка, вся компиляция идётspawn-per-request в `-compile-only`
  через указанный бинарь.
- MCP `daslang` намеренно НЕ переопределён: сервер сессии живёт на
  `/root/daScript/bin/daslang`. Его результаты — dev-подсказка; авторитетен
  гейт из AGENTS.md. При перезапуске сессию можно перевести и MCP на
  `tmp/daslang-toolchain` (в нём полная копия дерева: `utils/mcp/main.das`,
  `dastest/`, `daslib/`) — решение за владельцем.
- Эффект override — после quit/restart opencode (конфиг читается один раз на
  старте). До рестарта сессия использует уже загруженный глобальный конфиг.

## Проверка

- Ручной LSP-хендшейк: initialize ok, publishDiagnostics приходят.
- На запись `opencode.json` LSP немедленно запушил реальные ошибки рабочего
  дерева (`source/m3_module.das`: `FreeImportInfo` mismatch, void-касты;
  `source/m3_core.das:585`: `string& = void?`) — это незакоммиченное
  состояние после GLM-сессии, диагностика адекватна.
- `tmp/daslang-toolchain/bin/daslang --version` → 0.6.4 (pin).

## Правила в AGENTS.md

Добавлен раздел «Tooling policy — interacting with .das (MANDATORY)»: весь
`.das` только через read/edit/write + `daslang_*` MCP (навигация,
compile_check, lint, format_file, run_test, introspection); bash — только git
и команды гейта; grep/glob — только по C-эталону `wasm3c/` и не-`.das`
файлам; LSP-пуши с ERROR считаются stop-ship.
