# Codex Onboard After GLM + Qwen

## Цель

Продолжить `wasm3das` с текущей точки, не повторяя исследования GLM/Qwen и не используя самодельный DAP/MCP harness Qwen.

Главная цель сейчас:

`real wasm correctness -> teardown correctness -> regression -> cleanup`

Не возвращаться к массовой lint/style-чистке, пока runtime lifecycle не доказан.

---

## 0. ВАЖНО: происхождение текущего `source/`

Текущий `source/` нельзя считать безусловно каноничным только потому, что он компилируется и проходит существующие unit tests.

До Qwen GLM делал крупные механические C→Daslang merge/fix:

* массовые Python/regex-преобразования `m3_parse.das` и `m3_module.das`;
* собственный stripper `m3log(...)`, который в одном из прогонов физически обрезал начало обоих файлов;
* regex-правки pointer typedef'ов, которые местами превращали уже-pointer typedef вроде `IM3Function` в фактический double pointer;
* попытки обернуть C-макросы `m3_Free` / `m3_ReallocArray` в generic helpers, позже отменённые в пользу явного раскрытия C-макросов;
* перенос функций между `m3_env` и `m3_module`, после которого некоторое время существовали duplicate definitions.

Большая часть этих проблем затем была исправлена, поэтому НЕ считать текущий source автоматически повреждённым.

Но если встречается странный код, особенно в `m3_parse.das`, `m3_module.das`, `m3_core.das`, `m3_env.das`, сначала проверить provenance через Git и оригинальный C, а не достраивать поверх него ещё один workaround.

---

## 1. Сначала сохранить текущее состояние

Перед любыми source-правками:

```bash
git status --short
git diff --stat
git diff > /tmp/codex-onboard-start.patch
git log --oneline --decorate --graph -12
```

Опорный committed checkpoint Qwen:

```text
7c25b78  Fix wasm magic byte order and module deallocation found via DAP stepping
9a2058e  Phase 2: wire CompileFunctionHook/ResizeMemoryHook at m3_NewEnvironment
5fb3c38  Record phase 1 outcome and lint findings distribution
```

`7c25b78` — полезная чистая точка сравнения, но НЕ абсолютная semantic truth: после неё Qwen обнаружил дополнительные runtime bugs.

### Запрещено на старте

Не делать:

```bash
git reset --hard
git checkout -- source/
git restore source/
```

Не восстанавливать целый файл поверх текущего working tree до проверки diff: после `7c25b78` есть важные Qwen source-fix, которые могут быть незакоммичены.

---

## 2. Как восстанавливать подозрительный source

Если файл выглядит механически испорченным — например:

* обрезанная шапка;
* дублированные строки;
* бессмысленные `unsafe`;
* странный `reinterpret(addr(...))`;
* pointer typedef с лишним `?`;
* функция оказалась не в том модуле;
* generic helper имитирует C macro и даёт подозрительную типизацию;

НЕ чинить повреждение по памяти.

Сначала:

```bash
git log --oneline -- source/m3_module.das
git diff 7c25b78 -- source/m3_module.das
git show 7c25b78:source/m3_module.das > /tmp/m3_module.7c25b78.das
diff -u /tmp/m3_module.7c25b78.das source/m3_module.das
```

Для любого спорного участка сравнить три версии:

```text
current Das
    ↕
последний подходящий Git commit
    ↕
wasm3c/source/*.c
```

Git использовать как источник восстановления уже отслеживаемого кода.

Оригинальный `wasm3c/source/*.c` использовать как источник semantic ownership и pointer/allocator semantics.

Если доказано, что current hunk — механическое повреждение GLM, восстановить только этот hunk или конкретный файл из выбранного commit и затем повторно применить доказанные более поздние Qwen-fix.

---

## 3. Особо подозрительные зоны после GLM

### `m3_module.das`

Это самый высокий приоритет аудита.

GLM вручную переписывал полный `m3_module`, исправлял pointer indexing, `m3_Free`, `m3_ReallocArray`, string/null semantics.

Ключевое правило:

> Сначала определить, что хранит C-массив: struct или pointer.

Пример уже найденного Qwen бага:

```c
IM3FuncType ft = io_module->funcTypes[i_typeIndex];
```

`funcTypes` — массив pointer values.

Правильно в Daslang:

```das
unsafe {
    var ft : IM3FuncType = io_module.funcTypes[i_typeIndex]
}
```

Неправильно:

```das
reinterpret<IM3FuncType>(addr(io_module.funcTypes[i_typeIndex]))
```

`addr(slot)` здесь даёт адрес ячейки массива, то есть pointer-to-pointer semantics вместо stored pointer.

Не распространять автоматически идиому `addr(array[i])` между:

```text
array of structs
array of pointers
```

---

### `m3_env.das`

GLM/внешний агент временно дублировали здесь `Module_FreeFunctions` и `m3_FreeModule`.

Ownership должен соответствовать C:

```text
m3_module.c -> m3_module.das
m3_env.c    -> m3_env.das
```

Не возвращать duplicate implementations ради устранения compile error.

Отдельно проверять allocator pairing.

---

### `m3_core.das`

GLM экспериментировал с generic версиями C macros.

Не вводить обратно generic `m3_Free(auto&)` / `m3_ReallocArray(auto)` без доказательства корректной typed-pointer семантики.

C macros предпочтительно раскрывать явно в местах использования, если Daslang generic начинает менять тип результата.

---

### `m3_parse.das`

GLM заменял частичный parser полным 17/17 parser и механически удалял `m3log`.

Если обнаружится структурно странный участок — сначала сравнить с Git и `wasm3c/source/m3_parse.c`.

Не писать новый parser поверх существующего.

---

## 4. Allocation ownership — проверять всегда

Не считать все указатели одинаковыми.

Обязательная таблица:

```text
Daslang new T()      <-> delete
m3_Malloc_Impl(...)  <-> m3_Free_Impl(...)
```

Уже были найдены ошибки в обе стороны:

```text
new M3Module()
    -> ошибочно m3_Free_Impl
    -> должно delete
```

и:

```text
AllocFuncType -> m3_Malloc_Impl
    -> ошибочно delete
    -> должно m3_Free_Impl
```

При любом teardown crash сначала определить provenance allocation конкретного pointer.

Не выбирать `delete/free` по типу объекта или имени функции.

---

## 5. Независимо проверить и сохранить post-Qwen fixes

После `7c25b78` Qwen нашёл как минимум два важных source-fix, которые необходимо независимо проверить в текущем working tree.

### Fix A — `Module_AddFunction`

`m3_module.das`:

`funcTypes[i_typeIndex]` должен читаться как stored pointer value.

Не использовать `addr(slot)`.

Это исправляет сломанную связь:

```text
function
    -> funcType
        -> numArgs / numRets
```

и было причиной runtime compiler симптомов вроде:

```text
numArgs = 0
numRets = 0
local index out of bounds
```

---

### Fix B — `Environment_Release`

`M3FuncType`, созданный через `m3_Malloc_Impl`, должен освобождаться через `m3_Free_Impl`.

Не через `delete`.

Проверить это независимо по:

```text
AllocFuncType
Environment_AddFuncType
Environment_Release
```

и C `m3_env.c`.

---

## 6. Gate перед новым debugging

После сохранения working tree и проверки двух post-Qwen fixes:

1. compile всех `source/*.das`;
2. compile tests;
3. полный `dastest`;
4. запуск real `fib32` runner.

Не использовать lint как blocker на этом этапе.

Старый lint backlog большой и в основном не относится к текущему runtime correctness.

---

## 7. Подтверждённое runtime-состояние

Реальный `fib32.wasm` уже прошёл:

```text
parse
load
compile
find export "fib"
execute
read result
```

Подтверждены:

```text
fib(2)  = 1
fib(10) = 55
fib(25) = 75025
```

То есть НЕ начинать debugging снова с parser/compiler, если новый evidence прямо не показывает regression.

Для fib runner временно использовался увеличенный Daslang stack из-за отсутствия эквивалента C `M3_MUSTTAIL`.

Trampoline / tail-call architecture — отдельная будущая задача, не смешивать с teardown.

---

## 8. Текущая основная проблема

Основная незакрытая проблема:

```text
SIGSEGV during teardown
```

Execution результата уже корректен.

Падение связано с lifecycle/free path.

Основной call path:

```text
m3_FreeRuntime
    -> Runtime_Release
        -> ForEachModule
            -> _FreeModule
                -> m3_FreeModule
```

Не возвращаться к compiler до появления evidence, что teardown corruption возникает раньше.

---

## 9. Куда продолжать DAP

Использовать только настроенный DAP Codex.

Не восстанавливать и не развивать:

```text
tools/dapdrive.py
tools/dasdap_mcp.py
logs/probe*.py
```

Qwen уже потратил много времени на собственный DAP/MCP harness; Codex должен использовать штатный debugger.

### Первый invariant

Перед входом в teardown доказать:

> `runtime.modules` указывает на тот же валидный `IM3Module`, который был создан `m3_ParseModule` и загружен в runtime.

На breakpoints снять:

```text
runtime.modules
_module
next
i_module
call stack
```

Дальше идти по одному ownership invariant за раз.

Для каждого освобождаемого объекта фиксировать:

```text
pointer
allocated by
owned by
freed by
expected allocator pair
```

---

## 10. Отдельно проверить linked-list teardown

Особое внимание:

```text
runtime.modules
module.next
environment.funcTypes
funcType.next
pagesOpen
pagesFull
pagesReleased
```

Перед освобождением элемента сохранить `next`.

Проверить, что callback/visitor не обращается к уже освобождённому container или next pointer.

Не менять teardown код по гипотезе без breakpoint evidence.

---

## 11. Scratch-артефакты Qwen

После сохранения полезного evidence удалить локальный scratch, если он ещё существует:

```text
tools/dapdrive.py
tools/dasdap_mcp.py
logs/mcp_probe*.py
logs/probe*.py
logs/run*.json
logs/dasdap_*
logs/cc*.das
logs/callcount.das
logs/free_probe.das
```

Также убрать регистрацию Qwen DAP MCP из `opencode.json`, если она осталась.

`tools/teardown_test.das`:

* либо удалить;
* либо превратить в один нормальный regression test стандартного test suite.

Gitignored scratch невозможно восстановить через историю Git, поэтому сначала убедиться, что там нет единственного экземпляра важного evidence.

---

## 12. Правило работы Codex

Не строить много гипотез одновременно.

Цикл:

```text
observation
    ->
one invariant
    ->
DAP + comparison with C
    ->
minimal patch
    ->
real fib regression
    ->
unit regression
    ->
commit
```

### Дополнительное правило после GLM

Не применять массовые regex/Python transformations к `source/*.das`, если изменение затрагивает pointer types, ownership, `unsafe`, allocator semantics или C macros.

Для механического изменения сначала:

1. проверить его на одном call site;
2. compile;
3. runtime/regression;
4. только затем расширять.

При подозрении на source corruption дешевле восстановить проверенный hunk из Git и заново применить доказанный fix, чем чинить результат нескольких автоматических transformations.

---

## 13. Commit discipline

Каждый доказанный runtime fix — отдельный commit.

Особенно отдельно коммитить:

1. восстановление механически повреждённого source, если такое обнаружится;
2. `funcTypes[i_typeIndex]` pointer-value fix;
3. allocator-pair fix;
4. teardown root-cause fix;
5. regression test.

В commit message писать не только «что изменено», но и доказанный invariant / C comparison.

Не смешивать runtime fix с lint/style cleanup.
