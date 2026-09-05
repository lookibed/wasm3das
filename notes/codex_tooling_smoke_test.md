# Codex: проверка daslang MCP, LSP и DAP

Эта заметка предназначена для новой Codex-сессии, запущенной из
`/root/wasm3das`. Она проверяет только подключение инструментов. Аудит и
изменение `wasm3das` начинаются после успешного smoke-теста.

## Стартовый промпт

Скопировать в новую сессию целиком:

```text
Работаем в /root/wasm3das. Пока не исследуй и не меняй исходники проекта.
Сначала выполни smoke-тест Codex tooling по инструкции
notes/codex_tooling_smoke_test.md.

Проверь cwd, Git root, trust проекта и загрузку .codex/config.toml. Затем
проверь три проектных MCP-сервера: daslang, daslang-lsp и daslang-dap.

1. Покажи, видны ли все три сервера в конфигурации и активны ли они в этой
   сессии.
2. Для daslang сделай безопасные list_modules и compile_check для
   source/m3_core.das.
3. Для daslang-lsp проверь все 8 tool schemas и вызови diagnostics и
   document_symbols для source/m3_core.das.
4. Для daslang-dap проверь наличие всех 21 debug_* tools из заметки, затем
   проведи минимальный launch smoke на /root/daScript/utils/dap/_fixture.das:
   launch -> threads -> configuration_done -> wait_event(terminated) ->
   disconnect. Не указывай port, не ставь breakpoints и не используй wasm3das
   runtime как debuggee в этом smoke-тесте. already_disconnected=true после
   terminated является успешным идемпотентным cleanup.
5. При любой ошибке не создавай новый bridge/harness и не редактируй .das.
   Пройди раздел диагностики этой заметки и сообщи точный сломанный слой.
6. Верни две таблицы: сводную по трем серверам и отдельную по 21 DAP tool со
   статусами yes/no/like_that/other_like. Приложи точный текст ошибок и пути
   релевантных логов.

Не исправляй код wasm3das, не делай commit/reset/restore и не удаляй чужие
логи или процессы. Созданные тобой одноразовые probes и завершенные probe-логи
убери после проверки.
```

## Ожидаемая конфигурация

Проектный файл: `/root/wasm3das/.codex/config.toml`.

Ожидаются три enabled/required STDIO-сервера:

| Сервер | Назначение | Реализация |
|---|---|---|
| `daslang` | Компилятор, навигация, lint, запуск и introspection | pinned `mcp_supervisor.py` из `tmp/daslang-toolchain` |
| `daslang-lsp` | LSP diagnostics/navigation через MCP | `/root/daScript/utils/lsp/mcp_bridge.py` |
| `daslang-dap` | Stateful DAP client через MCP | `/root/daScript/utils/dap/mcp_bridge.py` |

Pinned compiler для `daslang`, LSP и authoritative project gate:

```text
/root/wasm3das/tmp/daslang-toolchain/bin/daslang
```

DAP bridge и временно выбранный DAP executable:

```text
/root/daScript/utils/dap/mcp_bridge.py
/root/daScript/bin/daslang
```

Live executable нужен для исправленного statement stepping. До переноса этого
исправления в pinned toolchain не подменять им обычные compile/lint/test gates
и не переключать DAP обратно на старый pinned binary молча.

Проект должен быть trusted в `/root/.codex/config.toml`:

```toml
[projects."/root/wasm3das"]
trust_level = "trusted"
```

Codex игнорирует project-local `.codex/config.toml` для untrusted-проекта.
Tool schemas обнаруживаются при старте сессии, поэтому после изменения
конфигурации или bridge нужно полностью перезапустить сессию из корня проекта.

## Уровень 1: загрузилась ли конфигурация

До запуска Codex в обычном терминале:

```bash
cd /root/wasm3das
pwd
git rev-parse --show-toplevel
codex mcp list
codex mcp get daslang
codex mcp get daslang-lsp
codex mcp get daslang-dap
```

Ожидается:

- `pwd` и Git root равны `/root/wasm3das`;
- `codex mcp list` показывает все три сервера как enabled;
- пути в `codex mcp get` совпадают с `.codex/config.toml`;
- после запуска Codex команда `/mcp` показывает все три сервера активными.

`codex mcp list` проверяет разрешенную конфигурацию. `/mcp` внутри TUI
проверяет именно текущую сессию. Это разные проверки.

## Уровень 2: smoke каждого сервера

### daslang MCP

Минимальные native tool calls:

1. `list_modules` — сервер должен вернуть список модулей.
2. `compile_check(file="/root/wasm3das/source/m3_core.das")` — ожидается
   `Compilation OK.` без запуска shell-компилятора.

Количество инструментов может расти вместе с toolchain, поэтому жестким
критерием является наличие нужных операций, а не старое абсолютное число.

### daslang-lsp

Ожидаются ровно эти 8 tool schemas:

| Tool | Smoke |
|---|---|
| `diagnostics` | Вызвать для `source/m3_core.das`; получить список, допустимо пустой |
| `hover` | Достаточно подтвердить schema |
| `definition` | Достаточно подтвердить schema |
| `references` | Достаточно подтвердить schema |
| `document_symbols` | Вызвать для `source/m3_core.das`; получить symbols |
| `workspace_symbols` | Достаточно подтвердить schema |
| `implementation` | Достаточно подтвердить schema |
| `call_hierarchy` | Достаточно подтвердить schema |

Если названия показаны с префиксом сервера, например
`daslang-lsp.diagnostics`, это тот же инструмент и статус `yes`.

### daslang-dap

Должны быть доступны все 21 инструмента:

| # | Tool |
|---:|---|
| 1 | `debug_connect` |
| 2 | `debug_initialize` |
| 3 | `debug_launch` |
| 4 | `debug_attach` |
| 5 | `debug_set_breakpoints` |
| 6 | `debug_data_breakpoint_info` |
| 7 | `debug_set_data_breakpoints` |
| 8 | `debug_configuration_done` |
| 9 | `debug_threads` |
| 10 | `debug_stack_trace` |
| 11 | `debug_scopes` |
| 12 | `debug_variables` |
| 13 | `debug_evaluate` |
| 14 | `debug_continue` |
| 15 | `debug_pause` |
| 16 | `debug_step_in` |
| 17 | `debug_step_over` |
| 18 | `debug_step_out` |
| 19 | `debug_terminate` |
| 20 | `debug_disconnect` |
| 21 | `debug_wait_event` |

Минимальный runtime smoke использует только:

```text
debug_launch(/root/daScript/utils/dap/_fixture.das)
    -> debug_threads
    -> debug_configuration_done
    -> debug_wait_event(event="terminated")
    -> debug_disconnect
```

`debug_launch` вызывается без `port`: bridge сам выбирает свободный локальный
порт. Это проверяет запуск live DAP executable, TCP DAP, initialize/launch,
обязательный startup gate и завершение сессии. Остальные schemas достаточно
сверить со списком. После `terminated` всегда вызвать `debug_disconnect`:
`already_disconnected=true` с `session` snapshot является успешным результатом.
Полный bridge-test покрывает все 21 tool.

## Если инструменты не работают

### Не видны сразу все три сервера

Наиболее вероятные причины:

1. Codex запущен не из `/root/wasm3das`.
2. `/root/wasm3das` не отмечен trusted.
3. `.codex/config.toml` создан или изменен после запуска текущей сессии.
4. TOML не парсится.

Порядок действий:

1. Закрыть текущую Codex-сессию.
2. Проверить trust-запись и `/root/wasm3das/.codex/config.toml`.
3. Из `/root/wasm3das` выполнить `codex mcp list`.
4. Если три сервера видны, снова запустить `codex` из этой же директории.
5. В новой сессии проверить `/mcp`.

Не переносить эти записи в `opencode.json` или Claude settings: Codex берет их
из своих `config.toml` layers.

### `codex mcp list` видит сервер, а текущая сессия — нет

Сессия была запущена до регистрации сервера либо до изменения tool schemas.
Полностью перезапустить сессию. Новое сообщение в старом чате не перечитывает
schemas MCP.

### Не стартует только `daslang`

Проверить существование и права:

```text
/root/wasm3das/tmp/daslang-toolchain/bin/daslang
/root/wasm3das/tmp/daslang-toolchain/utils/mcp/mcp_supervisor.py
```

Проверить лог:

```text
/root/wasm3das/logs/codex-mcp-stderr.log
```

Типовые причины: отсутствует pinned toolchain, неверен `DASLANG_MCP_BIN`,
сломался Python launcher или startup занял больше 20 секунд. Не подменять
compiler системной версией: восстановить pinned toolchain по README проекта.

### Не стартует только `daslang-lsp`

Проверить четыре пути из `.codex/config.toml`:

```text
/root/daScript/utils/lsp/mcp_bridge.py
/root/wasm3das/tmp/daslang-toolchain/utils/lsp/lsp_supervisor.py
/root/wasm3das/tmp/daslang-toolchain/bin/daslang
/root/wasm3das/logs/codex-lsp.log
```

Если сервер зарегистрирован, но native call падает, сначала читать
`codex-lsp.log`. Для изоляции самого bridge из `/root/daScript` можно запустить:

```bash
PYTHONDONTWRITEBYTECODE=1 python3 utils/lsp/test_mcp_bridge.py
```

После исправления bridge или supervisor перезапустить Codex-сессию.

### Не стартует только `daslang-dap`

Проверить:

```text
/root/daScript/utils/dap/mcp_bridge.py
/root/daScript/bin/daslang
```

Для изоляции bridge из `/root/daScript`:

```bash
PYTHONDONTWRITEBYTECODE=1 python3 utils/dap/test_mcp_bridge.py
```

Тест запускает реальные debuggee и покрывает все 21 MCP tool. Отдельно
statement stepping проверяется так:

```bash
DAS_TEST_STEPPING=1 PYTHONDONTWRITEBYTECODE=1 python3 utils/dap/test_mcp_bridge.py
```

Гонку закрытия, reset соединения или зависание stepping не считать допустимым
случайным результатом и не маскировать повторным прогоном. Сохранить точную
ошибку и поля `session`: `return_code`, `close_reason`,
`last_dap_termination`, `process_output_tail`.

Если stateful DAP smoke оборвался посередине, сначала вызвать
`debug_disconnect`; повторный вызов безопасен. Не делать новый `debug_launch`,
пока прежняя сессия не отключена и принадлежащий bridge процесс не завершился.
Не перебирать вручную hard-coded ports и не убивать все процессы `daslang`
широким `pkill`: среди них могут быть активные MCP/LSP-процессы другой сессии.

### Сервер активен, но один tool падает

Это уже не проблема регистрации. Зафиксировать:

- server и точное имя tool;
- arguments без секретов;
- полный error/result;
- relevant log tail;
- воспроизводится ли после новой сессии;
- проходит ли соответствующий bridge-test.

Не заменять сломанный native tool shell-скриптом как постоянное решение.
Временный fallback допустим только для локализации слоя и должен быть явно
помечен в отчете.

## Формат отчета

Сводная таблица:

| Server | В config | В текущей сессии | Smoke | Статус | Evidence/log |
|---|---|---|---|---|---|
| `daslang` | yes/no | yes/no | pass/fail | yes/no/like_that/other_like | ... |
| `daslang-lsp` | yes/no | yes/no | pass/fail | yes/no/like_that/other_like | ... |
| `daslang-dap` | yes/no | yes/no | pass/fail | yes/no/like_that/other_like | ... |

Для DAP повторить отдельную таблицу по всем 21 именам. Значения:

- `yes` — точный native tool доступен и schema соответствует назначению;
- `no` — tool отсутствует;
- `like_that` — точный эквивалент доступен под server-qualified именем;
- `other_like` — есть лишь частичный или иной аналог; пояснить различие.

## Гигиена

- Диагностические логи хранить только в `/root/wasm3das/logs/` либо в
  существующих bridge logs.
- Не использовать deployment/toolchain directories как scratch.
- Не удалять пользовательские логи, pinned toolchain и активные процессы.
- После успешной проверки удалить только созданные этой проверкой одноразовые
  probes и завершенные probe-логи.
