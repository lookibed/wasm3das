# Обновление Codex DAP tooling — 2026-09-04

## Что изменено в `wasm3das`

- `.codex/config.toml` оставляет compiler MCP и LSP на проектном pinned
  toolchain, но запускает DAP через актуальные
  `/root/daScript/utils/dap/mcp_bridge.py` и `/root/daScript/bin/daslang`.
- `AGENTS.md` теперь задаёт точный stateful lifecycle для launch и attach,
  запрещает ручной перебор портов и объясняет диагностику закрытой сессии.
- `notes/codex_tooling_smoke_test.md` приведена к текущему контракту bridge:
  auto-port, идемпотентный disconnect и отдельный stepping smoke.
- Tool schema `debug_launch` в live bridge больше не помечает исправленный
  stepping-crash как находящийся в расследовании; выбор режима теперь описан
  как явный выбор между statement stepping и instrumentation.

После этих изменений нужна новая Codex-сессия, запущенная из
`/root/wasm3das`: уже работающая сессия не перечитывает project-local MCP
configuration и tool schemas.

## Почему DAP использует live daScript binary

Проектный pinned binary и live binary оба сообщают версию `0.6.4`, но это
разные сборки. Исправление statement-stepping race находится в live checkout
`/root/daScript` и ещё не перенесено в старую pinned копию внутри
`wasm3das/tmp/daslang-toolchain`.

Это исключение относится только к DAP. Компиляция, LSP и финальные
compile/lint/test gates `wasm3das` по-прежнему должны использовать:

```text
/root/wasm3das/tmp/daslang-toolchain/bin/daslang
```

## Причина исправленного stepping race

Проблема была в lifecycle и синхронизации native debug agent, а не в MCP
команде step и не в занятости TCP-порта:

- callbacks debugger adapter должны исполняться в настоящем
  `threadlock_context`, общем с pinvoke;
- запуск tick-thread откладывается до `onSimulateContext`, то есть после
  завершения построения/хеширования SimNode;
- до этой точки DAP обслуживается главным потоком;
- отдельный readiness path не допускает инверсии блокировок registry/context.

Из-за прежнего сбоя соединение могло умереть во время stepping. Следующий
`debug_launch` создавал уже новую debuggee-сессию; если старый listener ещё
жил, ручное использование порта `10000` давало вторичный `can't bind`. Поэтому
порт был симптомом неправильного восстановления после падения, а не причиной
stepping race.

## Канонический launch lifecycle

```text
debug_launch(file=..., stepping_debugger=true|false; port не задавать)
    -> debug_set_breakpoints (опционально)
    -> debug_threads
    -> debug_configuration_done
    -> debug_wait_event(stopped|terminated)
```

`debug_launch` уже выполняет connect, initialize и DAP launch. Повторять
`debug_connect`/`debug_initialize` после него не нужно. `debug_threads` до
`debug_configuration_done` — обязательный startup gate daScript.

После `stopped`:

```text
debug_stack_trace
    -> debug_scopes
    -> debug_variables / debug_evaluate
    -> continue или step
    -> debug_wait_event
```

Нужно просматривать все scopes. Debugger macros, подключаемые модулями через
`report_context_state`, появляются там же: например OpenGL и DECS могут
добавить собственные раскрываемые категории.

Default instrumentation mode подходит для обычной работы по breakpoint.
`stepping_debugger=true` нужно указывать для точного statement-level stepping.
В instrumentation mode первоначальный `verified=false` у breakpoint ещё не
является ошибкой: сначала требуется `configurationDone` и обработка последующих
breakpoint/stopped events.

## Завершение и восстановление после ошибки

Нормально завершить сессию через `debug_terminate` или `debug_disconnect`.
`debug_disconnect` идемпотентен: после уже закрытого peer он возвращает success,
`already_disconnected=true` и диагностический `session` snapshot.

При reset/EOF/timeout сначала сохранить:

- `connected`, `pid`, `return_code`;
- `close_reason` и `last_dap_termination`;
- `process_output_tail`;
- последнее реально полученное DAP event.

Затем вызвать `debug_disconnect`. Новый `debug_launch` допустим только после
disconnect прежней сессии и завершения принадлежащего bridge процесса. Не
назначать новые hard-coded ports и не применять широкий `pkill daslang`.

## Проверка после перезапуска Codex

Из новой сессии в `/root/wasm3das` выполнить smoke по
`notes/codex_tooling_smoke_test.md`. Для изоляции DAP bridge из
`/root/daScript` доступны два regression-прогона:

```bash
PYTHONDONTWRITEBYTECODE=1 python3 utils/dap/test_mcp_bridge.py
DAS_TEST_STEPPING=1 PYTHONDONTWRITEBYTECODE=1 python3 utils/dap/test_mcp_bridge.py
```

Первый проверяет стандартный instrumentation workflow, второй — native
statement stepping и его lifecycle regression. Reset соединения, зависание или
неожиданное завершение не следует считать flaky-pass и скрывать повтором.

## Состояние фикса

Исправления DAP/stepping пока находятся в незакоммиченном working tree
`/root/daScript`. Конфигурация `wasm3das` намеренно ссылается на эту live
сборку. Перед переносом проекта на другой хост или очисткой checkout нужно
сначала закоммитить/перенести исправления либо собрать эквивалентный binary и
обновить путь осознанно.
