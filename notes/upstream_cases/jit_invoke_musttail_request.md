# Прошение в форк daScript: хвостовой вызов через значение функции в LLVM JIT

Дата: 2026-09-22. От порта wasm3das (`/root/wasm3das`, PR #54). Техническая
версия на английском: `jit_invoke_musttail.md` рядом; микромодель:
`tests/jit_tests/dispatch.das`; смежная мелочь: `jit_ptr_inc_intrinsic.md`.

## Гипотеза

Тиры `-jit` и `-exe` порта отстают от тира `-ctx` (тот же daslang-код,
эмиттер C++ + g++) ровно в 2 раза на исполнении, потому что LLVM JIT
никогда не делает хвостовой вызов через значение функции. Если дать JIT
native-вход вызываемой функции и `musttail` в позиции `return`, exe и jit
получат ту же цепочку `jmp`, что ctx получает от gcc, и сравняются с ctx
без единой правки в порте.

## Что наблюдается

wasm3das это threaded-интерпретатор в форме C wasm3: каждая операция
заканчивается `return operation(_pc + 1, _sp, _mem, _r0, _fp0)`, где
`operation` прочитан из code page как значение функции
(`reinterpret<IM3Operation>(_pc[0])`). В C это `M3_MUSTTAIL return
nextOpImpl()`, и цепочка операций не растёт по стеку.

1. Дизассемблер кэшированной DLL порта (`.jitted_scripts/*/*.dll`,
   `objdump -d`, функция `m3_exec_defs::nextOpImpl` impl): вызов операции
   это `load simfn->jitFunction; call wrapper(ctx, args*, cmres)`, после
   него `ret`. Хвостового `jmp` нет и быть не может: у обёртки сигнатура
   `vec4f (Context *, vec4f * args, void * cmres)`, аргументы упакованы в
   массив `vec4f` на стеке вызывающего (alloca, адрес утекает), результат
   распакован из `vec4f`, после вызова сброс `context->stopFlags`.
2. Микромодель `tests/jit_tests/dispatch.das` (`daslang -jit`, O3,
   2 000 000 шагов, Ryzen 7 7435HS): один плоский invoke 4.4 нс;
   цепочка таких invoke 209 нс/шаг (кадры и страницы стека под ними);
   цепочка ПРЯМЫХ вызовов той же формы ~0 нс/шаг (LLVM делает хвостовой
   вызов и сворачивает в цикл); дерево прямых вызовов по индексу
   1.3 нс/шаг.
3. Порт, тихий стенд, 2026-09-21, `scripts/bench.sh`, fib(35): C wasm3
   0.374 с, ctx 0.538 с, exe 1.101 с, jit 2.043 с (тёплый кэш). Корпус
   фикстур без старта: ctx 0.6x C, exe 1.7x C, jit 3.9x C
   (`tests/manual/fixture_report.md`).
4. Эксперимент-заменитель на стороне порта (ветка
   `perf/jit-dispatch-tree`): индекс операции в слове code page и
   сгенерированное дерево прямых вызовов. LLVM делает `jmp` через дерево
   (503 хвостовых перехода в `m3_DispatchOp`), exe ускоряется, но
   центральный диспетчер стоит пролога и девяти сравнений на операцию, а
   ctx на нём в 1.7 раза медленнее. Значит, нужен именно хвостовой вызов
   через значение функции, а не обход.

## Где это в daslang

- `modules/dasLLVM/daslib/llvm_jit.das`: `visitExprInvoke` ->
  `build_call_dispatch` (загрузка `SIMFUNCTION_OFFSET_OF_JIT_FUNCTION`,
  вызов `g_t_jit_function`, `build_call_helper` как fallback);
  `visit_expr_return` (строит `ret` после `build_exit`/`build_epilogue`);
  `get_or_declare_impl` / `build_wrapper_function` (у каждой функции есть
  impl с native-сигнатурой и публичная обёртка).
- `include/daScript/simulate/simulate.h`: `struct SimFunction` (`code`,
  `aotFunction`, `jitFunction`, флаги); `das_instrument_jit` /
  `das_remove_jit` ставят и снимают `jitFunction`.

## Предлагаемое изменение

1. `SimFunction` получает поле `void * jitImpl` рядом с `jitFunction`:
   native-вход той же функции (impl, сигнатура `ret (args..., Context *)`),
   null для всего, что не JIT-нуто. `das_instrument_jit` ставит оба,
   `das_remove_jit` снимает оба. Для standalone/`-exe` заполняется там же,
   где сейчас `jitFunction`.
2. `build_call_dispatch` для значения типа `function<...>` с «простой»
   сигнатурой (каждый аргумент и результат: скаляр, указатель, строка,
   handle по значению; без cmres, без блоков и лямбд): загрузить `jitImpl`;
   если не null, прямой вызов impl с native-аргументами и `Context *`;
   иначе сегодняшний путь через обёртку. Сброс `stopFlags` после вызова
   оставить как есть.
3. В `visitExprReturn`, когда возвращаемое выражение это такой invoke и
   сигнатура вызывающей функции совпадает с сигнатурой вызываемой (случай
   threaded-интерпретатора: одна и та же `IM3Operation` у всех), ветка
   `jitImpl != null` строится как `musttail call impl(...)` + `ret`, без
   epilogue-кода между ними (в fallback-ветке всё по-старому). Условия
   `musttail` LLVM: одинаковые прототипы и calling convention, вызов
   непосредственно перед `ret`, никаких alloca вызывающего в аргументах.

## Как проверить

- Микромодель: `ulimit -s 4194304; daslang -jit
  notes/upstream_cases/tests/jit_tests/dispatch.das`. Критерий: строка
  `invoke-chain` опускается с ~209 нс/шаг до единиц нс, как `direct-chain`.
- Порт: `scripts/build_port.sh exe` и `scripts/wasm3-exe
  wasm3c/test/lang/fib32.wasm --func fib 35`. Критерий: ~0.55 с (уровень
  ctx) вместо 1.10 с. Дизассемблер: impl `nextOpImpl` заканчивается
  `jmp *%reg` через загруженный `jitImpl`, а не `call` + `ret`.
- Корректность: `run-spec-test.py` через `scripts/wasm3-exe --repl`
  17863/17863 (сейчас проходит), `run-wasi-test.py --fast` 7/7.

## Ожидаемый эффект

exe с 1.7x C до ~0.6x C на корпусе (уровень ctx), jit на исполнении так же;
у exe при этом старт 23 мс и никакого C++-компилятора в сборке. Для
daslang в целом: любой threaded-код, конечный автомат или интерпретатор
через таблицу функций перестаёт расти по стеку под JIT.

## Границы и риски

- Только «простые» сигнатуры; всё остальное идёт прежним путём.
- `-jit-stack` (логический стек daslang на каждый вызов) и `musttail`
  несовместимы по смыслу: при включённом `-jit-stack` musttail не
  ставить.
- Исключения: `jit_exception` уходит через `Context`, кадра вызывающего
  ему не нужно; проверить `evalWithCatch` вокруг точки входа.
- `das_remove_jit` обязан обнулить `jitImpl`, иначе повиснет указатель на
  выгруженную DLL.

## Смежная мелочь (отдельная просьба)

`jit_ptr_inc_intrinsic.md`: `p++`/`p--` на указателе это runtime-вызов
`$::i_das_ptr_inc` с указателем по ссылке (интринсики есть только для
`+=`/`-=`), что спиллит переменную и само по себе запрещает хвостовой
вызов. Две строки в `g_intrin_lookup` по образцу `i_das_ptr_set_add`.
Порт пока обошёл это написанием `_pc += 1`.
