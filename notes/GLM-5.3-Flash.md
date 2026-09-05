# GLM-5.3-Flash — журнал сессии интеграции wasm3 → daslang

Дата: 2026-08-30. Репо: `/root/wasm3das`. Цель сессии: довести порт до запуска
реального `.wasm` (эталон: `wasm3c/test/lang/fib32.wasm`, 62 байта, экспорт
`fib (i32)→i32`, fib(25)=75025) по цепочке parse → compile → link → execute.

Приоритеты (установлены владельцем): **работоспособность → Сишность → стиль**.
Lint отложен без риска; C-структуру не ломать (длинные функции — `nolint`, не сплит).

---

## 1. Стартовое состояние

- Принято и трекалось: 10 модулей (`m3_config`, `wasm3_defs`, `m3_math_utils`,
  `m3_core`, `m3_code`, `m3_function`, `m3_bind`, `m3_module`, `m3_types`,
  `m3_parse` — парсер только 4 секции из 17), 37 тестов зелёные.
- Покрытие по функциям C: ~20% принятого; черновики `m3_compile.das` (2341
  строка) и `m3_exec.das` (4242) не компилировались — требовали несуществующих
  `m3_env`/`m3_info`/`m3_exec_defs`.
- Внешний агент (ChatGPT через AutoSendGPT) отработал таски: `m3_env.das`,
  `m3_info.das`, `m3_module(2).das`, `m3_parse(1).das`, `wasm3.das` — все в
  `D:\Backups\AutosendGPT\Done`.

## 2. Что сделано

### 2.1 Типовой слой (я)
- **`source/m3_exception.das`** (новый): порт `m3_exception.h` — это макрос-слой;
  задокументирована развёртка `_try/_(X)/_throwif/_throwifnull` в ранние `return`.
- **`source/m3_exec_defs.das`** (новый): `m3MemData/m3MemRuntime/m3MemInfo`,
  typedef `IM3Operation = function<(...) : M3Result>`, `nextOpImpl/jumpOpImpl/
  nextOpDirect/jumpOpDirect`, `RunCode`.
- **`source/m3_types.das`** (расширен): полная структура `M3Runtime` (m3_env.h),
  `M3Environment`, `M3Memory`/`M3MemoryHeader`, `M3Compilation`/`M3CompilationScope`
  (m3_compile.h), `M3ErrorInfo`/`M3TaggedValue`/`M3SectionHandler`/`M3ImportContext`/
  `M3RawCall` (wasm3.h), `m3Error()` (m3_core.c, здесь из-за типов).
  Скаляры компилятора u16 → int (daslang не умеет арифметику на 8/16-бит),
  документировано в шапке.
- **`source/m3_core.das`**: + code-page типы (`code_t/pc_t/M3CodePage/M3CodePageHeader` —
  в C они в m3_core.h, были в m3_code.das), `d_m3CodePageFreeLinesThreshold`,
  `m3_ptr_addr` → public.
- **`source/m3_code.das`**: + пул страниц из m3_env.c (`AcquireCodePage*`,
  `ReleaseCodePage*`, `Environment_AcquireCodePage/ReleaseCodePages`,
  `RemoveCodePageOfCapacity`) — разрывает цикл env↔compile; `EmitWord`.
- **`source/m3_math_utils.das`**: + `M3_MAX`/`M3_MIN`.

### 2.2 m3_exec.das — ЗАКОМПИЛИРОВАН (4242 строки)
- 510 op-функций `def public op_*`; ABI: `(var _pc; var _sp; var _mem; var _r0; var _fp0) : M3Result`.
- Ключевое решение: **опы возвращают `M3Result`** (в C `m3ret_t = void*`,
  trap-payload = строка M3Result; в daslang строку нельзя протащить через `void?`).
- libm-заменители: `copysign_f32/f64`, `nearest_f32/f64` (wasm nearest = half-to-even).
- Хуки для разрыва циклов exec↔compile/env: `CompileFunctionHook`,
  `ResizeMemoryHook` (глобалы-функции, вайрятся в env).
- `c_memmove`/`c_memset` (в daslang нет), `@@op_X` для функций-значений.
- Gated-код (d_m3RecordBacktraces/OpTracing/OpProfiling) вырезан с комментариями.

### 2.3 m3_compile.das + m3_env.das — починены ВНЕШНИМ АГЕНТОМ
- Для агента создана таска `Tasks/daslang_manifest/`: **манифест языка** (187
  строк: elif, ключевики, function<>, не-nullable функции, let/var, unsafe,
  ширины int, sentinel вместо null-функций, ацикличность модулей, C-макросы) +
  эталонные файлы + файлы на починку.
- Агент вернул фикс: `m3_compile.das` (568 строк изменений) и `m3_env.das`
  (657) — **оба компилируются с 0 ошибок**. Интегрированы в `source/`.
- Манифест-фидбек №2 (после lint-прогона): PERF020/LINT004/STYLE034 — записать
  (ещё НЕ сделано).

### 2.4 Текущая сессия (merge парсера и модуля) — В ПРОЦЕССЕ
- `source/m3_parse.das` ← Done `m3_parse(1).das` (720 строк, 17/17 функций
  парсера, `m3_ParseModule` сам аллоцирует модуль — `m3_NewModule` в этой ветке
  wasm3 нет). Шапка адаптирована (`shared public`, относительные require),
  11 `m3log` вырезаны строково-осведомлённым стриппером.
- `source/m3_module.das` ← Done `m3_module(2).das` (10/10 функций) — переписан
  вручную: `unsafe{}`-блоки вокруг индексации, `reinterpret<T>(addr(...))`,
  `empty()` вместо `== null` для string-полей.
- **`source/m3_core.das`**: + `m3_Realloc_Impl`-обёртки; генерик `m3_Free(auto&)`
  удалён (конфликт со string-полями — C-макрос разворачивается в местах вызова:
  `m3_Free_Impl(p)` + `p = null`, строки → `p = ""`).
- Состояние компиляции сейчас: **13/15 PASS**; FAIL `m3_env.das` и `m3_parse.das`
  — по 2 ошибки «too many matching functions»: в env дублируются
  `Module_FreeFunctions`/`m3_FreeModule`, которые теперь есть и в m3_module.das.

## 3. Где встрял (точное место)

`m3_env.das:270-305` содержит вставки `Module_FreeFunctions` и `m3_FreeModule`
(агент инлайнил их, когда m3_module был частичным). Теперь это функции
m3_module.c → должны жить ТОЛЬКО в `m3_module.das`. Конфликт:
`m3_env.das:282` зовёт `Module_FreeFunctions` → «too many matching».

**Решение (следующий шаг):** удалить обе функции из `m3_env.das`, оставить
`_FreeModule` (он зовёт `m3_FreeModule` — это уже env-функция ForEachModule-
визитор). Проверить, что env вызывает `FreeImportInfo(g.import)` — там сигнатура
принимает `M3ImportInfo&` — env-вариант зовёт с `g.import` (поле по месту) —
ок. После удаления: compile_check дерева → должно быть 15/15.

## 4. Остаток пути к fib32

1. Удалить дубли из `m3_env.das` (см. выше) → 15/15 PASS.
2. Хуки в `m3_env.das`: `CompileFunctionHook = @@CompileFunction` (compile),
   `ResizeMemoryHook = @@ResizeMemory` — где-то при инициализации env
   (модульный глобал-инициализатор или явная функция `WireHooks`).
3. Раннер `run_fib32.das`: встроить 62 байта реального fib32.wasm
   (уже декодированы: type (i32)→i32, func 0, export "fib", тело 29 байт:
   local.get/const 2/lt_u/if-return/sub/call/call/add/return) →
   NewEnvironment → NewRuntime → m3_ParseModule → m3_LoadModule →
   m3_CompileModule → m3_FindFunction("fib") → m3_CallV([i32 25]) →
   m3_GetResultsV → print. Проверки: fib(2)=1, fib(10)=55, fib(25)=75025.
4. Отладка рантайма: compile.das и exec.das исполняются впервые — вероятны
   паники `d_m3Assert` (слотовая математика), трапы op_Call рекурсии,
   чтение результата из стека. При необходимости подключить `m3_info.das`
   из Done (SPrintArg/dump) для диагностики.
5. Эскалация: `fib64.wasm` (i64), модули с памятью/data из
   `wasm3c/test/regression/`, fio-чтение файла вместо встроенных байт.

## 5. Отложено (по решению владельца — «без риска по хребтине»)

- Lint: ~530 замечаний (PERF020 ~300 в exec — лишние same-type касты;
  LINT012 unused-args — лечится аннотацией `[unused_argument(...)]`;
  LINT004 локалы `_type` → переименовать; STYLE038/037 → узкий `// nolint`
  на длинных C-функциях и таблице операций — СИШНОСТЬ ВАЖНЕЕ).
- `format_file` (MCP-форматтер) по правленым файлам.
- Юнит-тесты новых слоёв (test_m3_compile/test_m3_env/test_m3_info/test_wasm3).
- `wasm3.das` фасад (раннер зовёт env напрямую), `m3_info.das` интеграция
  (диагностика, не критический путь), PORTING_MANIFEST.md (compile/exec/env/
  info/module/parse → Revision), фидбек №2 в манифест для агента.

## 6. Уроки (для следующих сессий)

- Инструменты: я долго скатывался в bash/python; MCP `lint` дал точную
  карту замечаний с локациями, LSP-пуши ловили ошибки сразу после write.
  НАЧИНАТЬ с них, а не догонять.
- `daslang` главное (полный манифест: `Tasks/daslang_manifest/daslang_manifest.txt`):
  - `elif`, не `else if`; `type/module/function/block` — ключевые слова.
  - Функции НЕ nullable → sentinel + `==`; значения функций через `@@fn`.
  - `let`=const: всё мутируемое — `var`; const тянется через указатели;
    `reinterpret<T>(x)`/`unsafe {}` снимает.
  - Арифметики на u8/u16 нет; скаляры компилятора — int; неявных
    преобразований ширины нет.
  - `unsafe(addr(...))`-выражение не защищает ИНДЕКСАЦИЮ — нужен блок
    `unsafe { }`; `addr(ptr[i])` даёт ref-квалифицированное значение —
    в переменную через явный тип или `reinterpret<T>(...)`.
  - Строки не nullable → `empty(x)` вместо `x == null`, `""` вместо NULL.
  - C-макросы (m3_Free/m3_ReallocArray/m3log) разворачивать в местах вызова —
    генерики с `auto&` конфликтуют со string-полями.
  - Циклы require запрещены: C-циклы include рвутся общим модулем типов
    (m3_types.das) или хуками-глобалами функций (CompileFunctionHook).
- Тесты runtime: M3Runtime — большая структура, только heap (`new M3Runtime()`),
  как в C m3_NewRuntime; в тестах не держать на стеке.

## 7. Быстрая проверка окружения

- Компилятор: `/root/daScript/bin/daslang -compile-only <file>` (0 ошибок = PASS).
- Тесты: `daslang /root/daScript/dastest/dastest.das -- --test tests` → 37/37.
- MCP: `compile_check`/`lint`/`format_file`/`run_test` (проект: `/root/wasm3das`).
- LSP: подключён (opencode.json → `/root/daScript/utils/lsp/lsp_supervisor.py`),
  пушит диагностику после каждого write.
- Git: 13 файлов отслеживаются; изменения пока НЕ закоммичены (фича-ветка
  не создавалась — по правилам репо только через PR).
