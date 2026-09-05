# daScript DAP debugger: практическая headless-интеграция для AI/CLI-агента

Эта инструкция предназначена для агента, который работает без VS Code и должен сам подключаться к встроенному DAP-дебаггеру `daScript` по TCP, ставить breakpoint'ы, получать стек/переменные, выполнять `evaluate`, делать `step/next/continue`, а при необходимости передавать управление native-debugger'у (`gdb`/`lldb`) для C/C++ кода.

Исходники, на которых основана инструкция:

- `daslib/debug.das` — встроенный DAP server/debug agent.
- `daslang/main.cpp` — включение debugger policy и автоматическое подключение `daslib/debug.das`.
- Репозиторий: <https://github.com/GaijinEntertainment/daScript>

---

## 1. Что именно запускает `--das-wait-debugger`

При запуске `daslang` с:

```bash
daslang script.das --das-wait-debugger
```

включается встроенный debugger mode.

В `daslang/main.cpp` для него выставляется debugger policy и добавляется extra module:

```cpp
policies.debugger = true;
access->addExtraModule("debug", getDasRoot() + "/daslib/debug.das");
```

В `debug.das` поднимается TCP DAP server.

Порт:

```text
--das-debug-port <port>
```

По умолчанию:

```text
10000
```

Пример:

```bash
daslang script.das \
  --das-wait-debugger \
  --das-debug-port 10000
```

После запуска процесс уже существует, DAP server уже работает, но выполнение debuggee удерживается до завершения debugger handshake.

Проверить:

```bash
ss -ltnp | grep 10000
```

или:

```bash
lsof -iTCP:10000 -sTCP:LISTEN
```

---

# 2. Это настоящий DAP

`daslib/debug.das` реализует Microsoft Debug Adapter Protocol.

Поддерживаются, среди прочего:

- `initialize`
- `launch`
- `attach`
- `configurationDone`
- `setBreakpoints`
- `threads`
- `stackTrace`
- `scopes`
- `variables`
- `continue`
- `pause`
- `next`
- `stepIn`
- `stepOut`
- `evaluate`
- data breakpoints

Транспорт — TCP.

Фрейминг сообщения стандартный DAP:

```text
Content-Length: <N>\r\n
\r\n
<JSON>
```

Например:

```text
Content-Length: 83\r\n
\r\n
{"seq":1,"type":"request","command":"initialize","arguments":{"adapterID":"das"}}
```

`Content-Length` — длина JSON payload в байтах, без заголовков.

---

# 3. Важнейшая особенность daScript handshake

Не считать, что одного `configurationDone` достаточно.

`wait_for_debugger()` в `debug.das` ожидает одновременно:

```text
configurationDone == true
threadsDone == true
```

`configurationDone` становится `true` после request:

```text
configurationDone
```

А `threadsDone` становится `true` только после request:

```text
threads
```

Поэтому минимальный клиент ОБЯЗАН вызвать `threads`.

Если забыть `threads`, процесс может выглядеть как "DAP подключился, configurationDone отправлен, но скрипт всё равно висит".

---

# 4. Рекомендуемый handshake

Практический порядок:

```text
TCP connect
    |
    v
initialize
    |
    v
initialize response
    |
    v
initialized event
    |
    v
launch или attach
    |
    v
setBreakpoints
    |
    v
threads
    |
    v
configurationDone
    |
    v
debuggee отпущен
```

После остановки:

```text
stopped event
    |
    +--> threads
    |
    +--> stackTrace
              |
              +--> scopes
                        |
                        +--> variables
    |
    +--> evaluate
    |
    +--> next / stepIn / stepOut / continue
```

---

# 5. Минимальный Python DAP transport

Ниже готовая база, которую агент может встроить в собственный tooling.

Создать файл:

```text
das_dap.py
```

```python
#!/usr/bin/env python3

import json
import socket
import itertools


class DAPClient:
    def __init__(self, host="127.0.0.1", port=10000):
        self.host = host
        self.port = port
        self.sock = None
        self.seq = itertools.count(1)
        self.pending = {}

    def connect(self):
        self.sock = socket.create_connection((self.host, self.port))

    def close(self):
        if self.sock:
            self.sock.close()
            self.sock = None

    def _recv_exact(self, size):
        chunks = []
        left = size

        while left:
            data = self.sock.recv(left)

            if not data:
                raise EOFError("DAP connection closed")

            chunks.append(data)
            left -= len(data)

        return b"".join(chunks)

    def send(self, obj):
        payload = json.dumps(
            obj,
            separators=(",", ":"),
            ensure_ascii=False,
        ).encode("utf-8")

        frame = (
            f"Content-Length: {len(payload)}\r\n\r\n".encode("ascii")
            + payload
        )

        self.sock.sendall(frame)

    def request(self, command, arguments=None):
        seq = next(self.seq)

        msg = {
            "seq": seq,
            "type": "request",
            "command": command,
        }

        if arguments is not None:
            msg["arguments"] = arguments

        self.send(msg)
        return seq

    def recv(self):
        headers = {}

        while True:
            line = self._readline()

            if line == b"":
                break

            name, value = line.decode("ascii").split(":", 1)
            headers[name.strip().lower()] = value.strip()

        length = int(headers["content-length"])
        payload = self._recv_exact(length)

        return json.loads(payload.decode("utf-8"))

    def _readline(self):
        buf = bytearray()

        while True:
            ch = self.sock.recv(1)

            if not ch:
                raise EOFError("DAP connection closed")

            if ch == b"\n":
                line = bytes(buf)

                if line.endswith(b"\r"):
                    line = line[:-1]

                return line

            buf.extend(ch)

    def wait_response(self, request_seq):
        while True:
            msg = self.recv()

            if (
                msg.get("type") == "response"
                and msg.get("request_seq") == request_seq
            ):
                return msg

            self.on_async_message(msg)

    def wait_event(self, name):
        while True:
            msg = self.recv()

            if msg.get("type") == "event" and msg.get("event") == name:
                return msg

            self.on_async_message(msg)

    def on_async_message(self, msg):
        print("DAP:", json.dumps(msg, ensure_ascii=False))


if __name__ == "__main__":
    dap = DAPClient()
    dap.connect()

    seq = dap.request(
        "initialize",
        {
            "adapterID": "das",
            "clientID": "headless-agent",
            "clientName": "Headless AI Agent",
            "linesStartAt1": True,
            "columnsStartAt1": True,
            "supportsVariableType": True,
        },
    )

    print(dap.wait_response(seq))

    print("waiting initialized...")
    print(dap.wait_event("initialized"))

    seq = dap.request("attach", {})
    print(dap.wait_response(seq))

    seq = dap.request("threads")
    print(dap.wait_response(seq))

    seq = dap.request("configurationDone")
    print(dap.wait_response(seq))

    print("debugger configured")

    while True:
        print(dap.recv())
```

---

# 6. Быстрая проверка подключения

Запустить debuggee:

```bash
./daslang test.das \
  --das-wait-debugger \
  --das-debug-port 10000
```

Во втором терминале:

```bash
python3 das_dap.py
```

Если handshake правильный, клиент должен получить:

```text
initialize response
initialized event
attach response
threads response
configurationDone response
```

После этого программа больше не должна зависать только из-за debugger gate.

---

# 7. Установка source breakpoint

daScript DAP `setBreakpoints` работает по:

```text
source.path + line
```

Это НЕ breakpoint по имени native-функции.

Пример request:

```python
seq = dap.request(
    "setBreakpoints",
    {
        "source": {
            "path": "/absolute/path/to/test.das"
        },
        "breakpoints": [
            {"line": 42},
            {"line": 87},
        ],
    },
)

response = dap.wait_response(seq)
print(response)
```

Рекомендуется использовать абсолютный путь.

Если проект запускается в контейнере/chroot/remote filesystem, обязательно следить за path mapping.

---

# 8. Правильный порядок setBreakpoints

Лучше ставить breakpoint'ы после `initialized`, но до `configurationDone`.

Например:

```python
dap.wait_event("initialized")

dap.wait_response(
    dap.request(
        "attach",
        {
            "cwd": "/work/project"
        },
    )
)

dap.wait_response(
    dap.request(
        "setBreakpoints",
        {
            "source": {
                "path": "/work/project/test.das"
            },
            "breakpoints": [
                {"line": 120}
            ],
        },
    )
)

dap.wait_response(dap.request("threads"))

dap.wait_response(dap.request("configurationDone"))
```

---

# 9. Обработка `stopped`

Когда breakpoint или step остановил execution, сервер пришлёт event вида:

```json
{
  "type": "event",
  "event": "stopped",
  "body": {
    "reason": "breakpoint",
    "threadId": 123
  }
}
```

Нужно извлечь:

```python
thread_id = msg["body"]["threadId"]
```

Затем запросить стек:

```python
seq = dap.request(
    "stackTrace",
    {
        "threadId": thread_id
    }
)

stack = dap.wait_response(seq)
```

---

# 10. Получение stack frames

Ответ `stackTrace` содержит примерно:

```json
{
  "body": {
    "stackFrames": [
      {
        "id": 123456,
        "name": "foo",
        "line": 42,
        "column": 1,
        "source": {
          "path": "/work/foo.das"
        }
      }
    ]
  }
}
```

Первый frame обычно интересует больше всего:

```python
frames = stack["body"]["stackFrames"]

frame = frames[0]

frame_id = frame["id"]
```

---

# 11. Scopes

Для frame:

```python
seq = dap.request(
    "scopes",
    {
        "frameId": frame_id
    }
)

scopes = dap.wait_response(seq)
```

В ответе будут scope'ы вроде:

```text
locals
arguments
globals
```

У каждого может быть:

```text
variablesReference
```

---

# 12. Variables

Если:

```python
variables_reference = scope["variablesReference"]
```

то:

```python
seq = dap.request(
    "variables",
    {
        "variablesReference": variables_reference
    }
)

variables = dap.wait_response(seq)
```

У переменной могут быть:

- `name`
- `value`
- `type`
- `variablesReference`

Если `variablesReference != 0`, объект можно раскрывать дальше рекурсивным `variables`.

Практический helper:

```python
def get_variables(dap, ref):
    seq = dap.request(
        "variables",
        {
            "variablesReference": ref
        }
    )

    response = dap.wait_response(seq)

    return response["body"]["variables"]
```

---

# 13. Evaluate

После stop можно вычислять выражения в context текущего frame.

Пример:

```python
seq = dap.request(
    "evaluate",
    {
        "expression": "foo",
        "frameId": frame_id,
        "context": "watch",
    },
)

result = dap.wait_response(seq)

print(result)
```

Можно использовать это для автоматических probe'ов:

```text
object.field
length(array)
some_debug_function(...)
```

То, что допустимо вычислять, зависит от debug evaluator daScript.

Не использовать evaluate как замену debugger stepping.

---

# 14. Continue

```python
seq = dap.request(
    "continue",
    {
        "threadId": thread_id
    }
)

print(dap.wait_response(seq))
```

После этого ждать:

```text
stopped
terminated
thread
output
```

---

# 15. Step over

DAP команда:

```text
next
```

```python
seq = dap.request(
    "next",
    {
        "threadId": thread_id
    }
)

dap.wait_response(seq)
```

Затем ждать нового:

```text
stopped
```

---

# 16. Step into

```python
seq = dap.request(
    "stepIn",
    {
        "threadId": thread_id
    }
)

dap.wait_response(seq)
```

---

# 17. Step out

```python
seq = dap.request(
    "stepOut",
    {
        "threadId": thread_id
    }
)

dap.wait_response(seq)
```

---

# 18. Pause

Если программа выполняется:

```python
seq = dap.request(
    "pause",
    {
        "threadId": thread_id
    }
)

dap.wait_response(seq)
```

После этого ждать `stopped`.

---

# 19. Минимальный debugger loop для AI-агента

Agent loop рекомендуется строить не как интерактивный терминал, а как state machine.

```text
CONNECTING
    |
    v
INITIALIZING
    |
    v
CONFIGURING
    |
    v
RUNNING
    |
    +-------------------------+
    |                         |
    v                         |
STOPPED                       |
    |                         |
    +--> inspect stack        |
    +--> inspect variables    |
    +--> evaluate probes      |
    +--> decide action        |
    |                         |
    +--> step / continue -----+
```

---

# 20. Практический action API для агента

Вместо того чтобы заставлять LLM самостоятельно строить сырой DAP JSON, лучше дать ему tool wrapper.

Например:

```python
class DasDebugger:
    def connect(self):
        ...

    def set_breakpoint(self, path, line):
        ...

    def continue_(self, thread_id):
        ...

    def next(self, thread_id):
        ...

    def step_in(self, thread_id):
        ...

    def step_out(self, thread_id):
        ...

    def stack(self, thread_id):
        ...

    def scopes(self, frame_id):
        ...

    def variables(self, ref):
        ...

    def evaluate(self, frame_id, expression):
        ...
```

LLM/agent тогда работает командами высокого уровня:

```text
set_breakpoint(path, line)
continue
stack
locals
evaluate(expr)
next
```

а transport скрыт внутри adapter'а.

---

# 21. Что агент должен логировать

Обязательно писать JSONL trace.

Например:

```json
{"direction":"send","command":"initialize","seq":1}
{"direction":"recv","type":"response","command":"initialize"}
{"direction":"recv","type":"event","event":"initialized"}
{"direction":"send","command":"setBreakpoints","seq":3}
{"direction":"recv","type":"event","event":"stopped","reason":"breakpoint"}
```

Плюс high-level trace:

```text
[debug] connected 127.0.0.1:10000
[debug] initialized
[debug] breakpoint /work/main.das:314 verified
[debug] stopped thread=938 reason=breakpoint
[debug] frame foo @ main.das:314
[debug] continue
```

Это критично для autonomous debugging: иначе агент не сможет отличить собственную ошибку orchestration от бага debuggee.

---

# 22. Таймауты

Никогда не делать бесконечный blocking `recv()` без watchdog.

Например:

```python
dap.sock.settimeout(10.0)
```

Но event wait может занимать дольше.

Лучше:

- transport timeout: 1–5 секунд;
- event loop: повторять чтение;
- overall operation deadline держать снаружи.

При timeout не считать debuggee мёртвым сразу.

Проверить:

```bash
kill -0 "$PID"
ss -tnp | grep 10000
```

---

# 23. Не путать source debugger и native debugger

Это самый важный архитектурный момент.

daScript DAP debugger умеет debug'ить daScript execution.

Он НЕ является заменой:

```text
gdb
lldb
WinDbg
```

для нативного C/C++ кода.

Например функции:

```text
m3_NewEnvironment
m3_NewRuntime
m3_ParseModule
```

если это функции wasm3 из native C library, нельзя просто передать их имена в `setBreakpoints`.

`setBreakpoints` в daScript работает по `.das` source line.

То есть:

```text
source.path
line
```

а не:

```text
symbol = m3_ParseModule
```

---

# 24. Как практически ловить баг внутри `m3_*`

Лучший workflow — два debugger'а одновременно.

## Уровень 1: daScript DAP

Поставить breakpoint на строку `.das`, откуда вызывается native binding:

```das
let runtime = m3_NewRuntime(...)
```

DAP останавливает процесс ПЕРЕД/ВОКРУГ вызова.

Получить:

- daScript stack;
- arguments;
- globals;
- состояние wrappers;
- pointers/handles, если доступны через evaluate.

## Уровень 2: gdb/lldb

Тот же процесс attach'ится native-debugger'ом.

Например:

```bash
gdb -p <PID>
```

Дальше:

```gdb
break m3_NewEnvironment
break m3_NewRuntime
break m3_ParseModule
continue
```

DAP удерживает процесс на хорошо определённой точке daScript, после чего native debugger ловит вход в C.

---

# 25. Рекомендуемый hybrid workflow

```text
daslang
   |
   +--> daScript VM
   |      |
   |      +--> DAP TCP :10000
   |
   +--> native bindings
          |
          +--> wasm3 / C / C++
```

Управление:

```text
AI agent
   |
   +--> das DAP adapter
   |
   +--> gdb/lldb controller
```

Последовательность:

```text
1. start daslang --das-wait-debugger
2. connect DAP
3. breakpoint on .das caller
4. threads
5. configurationDone
6. continue
7. wait stopped
8. inspect das state
9. attach gdb/lldb to same PID
10. native break m3_ParseModule
11. continue through DAP/native debugger carefully
12. inspect native stack/heap
```

---

# 26. Heap corruption: лучше ASan

Если цель — "найти место порчи кучи", stepping может быть хуже AddressSanitizer.

Пересобрать native часть с:

```bash
-fsanitize=address
-fno-omit-frame-pointer
-g
```

Для clang/gcc.

Типичный набор:

```bash
CFLAGS="-O1 -g -fsanitize=address -fno-omit-frame-pointer"
CXXFLAGS="-O1 -g -fsanitize=address -fno-omit-frame-pointer"
LDFLAGS="-fsanitize=address"
```

Запуск:

```bash
ASAN_OPTIONS=abort_on_error=1:detect_leaks=0 \
./daslang script.das --das-wait-debugger
```

DAP нужен, чтобы привести runtime к интересующей точке.

ASan нужен, чтобы поймать реальный illegal write/read.

---

# 27. Hardware watchpoint

Если адрес испорченного объекта уже известен, в gdb:

```gdb
watch *(uint64_t *)0xADDRESS
continue
```

или:

```gdb
awatch *(char *)0xADDRESS
```

Когда кто-то пишет туда, native debugger остановит инструкцию-виновника.

Это обычно намного эффективнее printf-бисектинга.

---

# 28. Как интегрировать это "нативно" в autonomous agent

Рекомендуемая архитектура:

```text
Agent
 |
 +-- DebugCoordinator
      |
      +-- DasDAPSession
      |
      +-- NativeDebuggerSession
      |
      +-- ProcessController
      |
      +-- ObservationStore
```

## DasDAPSession

Отвечает только за:

```text
connect
initialize
attach
breakpoints
threads
stackTrace
scopes
variables
evaluate
continue
step
pause
```

## NativeDebuggerSession

Отвечает за:

```text
gdb/lldb attach
break symbol
backtrace
registers
memory
watchpoints
continue
```

## DebugCoordinator

Принимает решения:

```text
"остановились в .das перед native call"
        |
        v
"поставить native breakpoint"
        |
        v
"continue"
        |
        v
"native breakpoint hit"
        |
        v
"снять native stack + inspect arguments"
```

---

# 29. Agent tool schema

Для LLM желательно предоставить такие действия:

```text
das_debug_connect(host, port)

das_breakpoint_set(file, line)

das_continue(thread)

das_step_over(thread)

das_step_into(thread)

das_step_out(thread)

das_stack(thread)

das_locals(frame)

das_evaluate(frame, expression)

native_attach(pid)

native_break(symbol)

native_backtrace()

native_watch(address, size)

native_continue()
```

Не давать LLM напрямую raw socket API, кроме режима диагностики debugger adapter'а.

---

# 30. Автоматический snapshot при каждом stop

Очень полезно: каждый `stopped` автоматически превращать в структурированный snapshot.

Например:

```json
{
  "reason": "breakpoint",
  "thread": 1234,
  "top_frame": {
    "function": "load_module",
    "file": "/work/test.das",
    "line": 512
  },
  "stack": [],
  "locals": {},
  "arguments": {},
  "evaluations": {}
}
```

Agent получает не raw protocol, а готовую observation.

---

# 31. Простая функция snapshot

Псевдокод:

```python
def snapshot(dap, stopped_event):
    thread_id = stopped_event["body"]["threadId"]

    stack = dap.stack(thread_id)

    if not stack:
        return {
            "thread": thread_id,
            "stack": [],
        }

    top = stack[0]

    scopes = dap.scopes(top["id"])

    result = {
        "thread": thread_id,
        "stack": stack,
        "scopes": {},
    }

    for scope in scopes:
        ref = scope["variablesReference"]

        result["scopes"][scope["name"]] = dap.variables(ref)

    return result
```

---

# 32. Полезная agent policy

В autonomous debugger полезно жёстко прописать:

```text
1. Никогда не делать continue, не сохранив snapshot stop state.
2. Никогда не делать больше N step подряд без анализа.
3. Если breakpoint не hit — проверить path/line и verified status.
4. Если configurationDone не отпускает процесс — проверить, был ли threads.
5. Если цель находится внутри native C/C++ — перейти к gdb/lldb/ASan.
6. Не пытаться ставить native symbol через DAP setBreakpoints.
7. Хранить все request/response/event в trace.
```

---

# 33. Как агенту самому понять, что DAP работает

Checklist:

```text
[ ] TCP connection established
[ ] initialize response success=true
[ ] initialized event received
[ ] attach/launch success=true
[ ] setBreakpoints success=true
[ ] threads success=true
[ ] configurationDone success=true
[ ] debuggee execution resumed
[ ] stopped event received
[ ] stackTrace returns frames
[ ] scopes returns refs
[ ] variables returns values
[ ] next causes next stopped event
```

Если первые 6 пунктов есть, adapter transport и handshake практически наверняка корректны.

---

# 34. Типовая ошибка №1: отправлен только configurationDone

Симптом:

```text
connected
initialize OK
configurationDone OK
process still waiting
```

Причина:

```text
threadsDone == false
```

Исправление:

```python
dap.wait_response(dap.request("threads"))
dap.wait_response(dap.request("configurationDone"))
```

---

# 35. Типовая ошибка №2: breakpoint не срабатывает

Проверить:

1. абсолютный путь;
2. существует ли source file;
3. та ли строка;
4. не оптимизирован/не инструментирован ли участок;
5. response `setBreakpoints`;
6. `verified`;
7. path aliases / cwd.

Не начинать менять transport до проверки source mapping.

---

# 36. Типовая ошибка №3: попытка break по C-symbol

Неправильно:

```json
{
  "command": "setBreakpoints",
  "arguments": {
    "function": "m3_ParseModule"
  }
}
```

Для этого DAP server такой breakpoint не является обычным source breakpoint.

Правильно:

```text
DAP:
  breakpoint на .das строку вызова m3_ParseModule

gdb/lldb:
  break m3_ParseModule
```

---

# 37. Типовая ошибка №4: agent читает только response

DAP асинхронный.

Между request и response могут приходить:

```text
event
output
thread
stopped
initialized
```

Поэтому нельзя:

```python
send(request)
recv()
# считать, что это обязательно response
```

Нужно route'ить сообщения по:

```text
type=response
request_seq=<seq>
```

А event'ы складывать отдельно.

---

# 38. Production transport architecture

Нормальный adapter лучше сделать с отдельным reader thread:

```text
socket reader
   |
   +--> responses[request_seq]
   |
   +--> events queue
```

Например:

```python
responses = {}
events = queue.Queue()
```

Reader:

```python
while running:
    msg = recv_message()

    if msg["type"] == "response":
        responses[msg["request_seq"]].set_result(msg)

    elif msg["type"] == "event":
        events.put(msg)
```

Так agent не потеряет `stopped`, пока ждёт другой response.

---

# 39. Практический async вариант

Если агент уже на `asyncio`, transport можно сделать через:

```python
reader, writer = await asyncio.open_connection(
    "127.0.0.1",
    10000,
)
```

Дальше:

```python
header = await reader.readuntil(b"\r\n\r\n")
```

найти `Content-Length`, затем:

```python
body = await reader.readexactly(length)
```

Это удобнее для agent runtime с параллельным process supervision.

---

# 40. Что считать "нативной интеграцией"

Для AI/CLI agent "нативно интегрировать debugger" означает:

НЕ:

```text
LLM пишет каждый раз временный Python script
```

а:

```text
в agent runtime есть постоянный debugger adapter
```

который предоставляет операции как обычные tools.

Например internal RPC:

```json
{
  "tool": "das.stack",
  "thread": 34
}
```

ответ:

```json
{
  "frames": [
    {
      "id": 123,
      "function": "foo",
      "file": "/src/foo.das",
      "line": 77
    }
  ]
}
```

Тогда модель работает с debugger'ом так же, как с shell/git/filesystem tools.

---

# 41. Рекомендуемый MVP

Для первого рабочего варианта реализовать только:

```text
connect
initialize
attach
setBreakpoints
threads
configurationDone
wait stopped
stackTrace
scopes
variables
evaluate
continue
next
stepIn
stepOut
disconnect
```

Этого уже хватает для полноценной автоматизированной source debugging session.

Не начинать с data breakpoints, custom path aliases и сложной UI-совместимости.

---

# 42. MVP CLI

Очень удобный слой:

```bash
dasdap connect 127.0.0.1:10000

dasdap break /work/main.das:342

dasdap run

dasdap stack

dasdap locals

dasdap eval 'foo.bar'

dasdap next

dasdap continue
```

А agent вызывает этот CLI как инструмент.

Позже transport можно встроить прямо в agent process.

---

# 43. Практический сценарий для wasm3 crash

Допустим есть код:

```das
...
let env = m3_NewEnvironment()
let runtime = m3_NewRuntime(env, ...)
let mod = m3_ParseModule(...)
...
```

## Шаг 1

Поставить breakpoint на строку перед подозрительным native call:

```text
main.das:417
```

## Шаг 2

Запустить:

```bash
daslang main.das \
  --das-wait-debugger \
  --das-debug-port 10000
```

## Шаг 3

Agent подключает DAP и делает:

```text
initialize
attach
setBreakpoints
threads
configurationDone
```

## Шаг 4

Получает:

```text
stopped main.das:417
```

## Шаг 5

Сохраняет:

```text
stack
locals
arguments
handles
pointer-like values
```

## Шаг 6

Attach native debugger:

```bash
gdb -p <daslang-pid>
```

## Шаг 7

В gdb:

```gdb
break m3_NewEnvironment
break m3_NewRuntime
break m3_ParseModule
continue
```

## Шаг 8

Через DAP дать `next`/`continue`, чтобы пройти к native call.

## Шаг 9

GDB должен остановиться внутри `m3_*`.

Теперь анализировать уже native stack, memory, ASan/watchpoints.

---

# 44. Разделение ответственности

| Задача | daScript DAP | gdb/lldb |
|---|---:|---:|
| breakpoint `.das` | Да | Неудобно |
| daScript stack | Да | Нет/плохо |
| daScript locals | Да | Нет/плохо |
| evaluate `.das` | Да | Нет |
| step по `.das` | Да | Нет |
| breakpoint C-symbol | Нет | Да |
| native stack | Нет | Да |
| registers | Нет | Да |
| raw memory | Ограниченно | Да |
| hardware watchpoint | Нет | Да |
| heap corruption | Косвенно | Да |
| ASan report | Нет | Да |

---

# 45. Главный вывод для агента

Не воспринимать `--das-wait-debugger` как загадочный proprietary debug port.

Это встроенный DAP server.

Правильная mental model:

```text
daScript process = DAP server
headless agent   = DAP client
```

Для source-level daScript debugging агент может полностью заменить VS Code.

Но DAP daScript не заменяет native debugger для C/C++ библиотек.

Для native corruption использовать связку:

```text
daScript DAP
+
gdb/lldb
+
ASan/watchpoints
```

---

# 46. Минимальный алгоритм, который стоит встроить в агента

```text
START DEBUG SESSION

1. Spawn:
   daslang target.das --das-wait-debugger --das-debug-port PORT

2. Wait until TCP PORT accepts connections.

3. DAP connect.

4. Send initialize.

5. Wait initialize response.

6. Wait initialized event.

7. Send attach.

8. Set requested .das source breakpoints.

9. Send threads.
   IMPORTANT: required by daScript wait logic.

10. Send configurationDone.

11. Enter event loop.

12. On stopped:
    a. get threadId
    b. stackTrace
    c. scopes top frame
    d. variables
    e. requested evaluate expressions
    f. save snapshot

13. Ask reasoning layer what to do:
    next / stepIn / stepOut / continue

14. If target enters native C/C++:
    attach gdb/lldb
    set native symbol breakpoint/watchpoint
    continue with coordinated control.

END DEBUG SESSION
```

---

# 47. Ссылки в исходниках

Основные места, которые стоит открыть агенту при сомнениях:

```text
daslib/debug.das
```

Искать:

```text
wait_for_debugger
wait_debugger
startServer
reqInitialize
reqConfigurationDone
reqThreads
reqSetBreakpoints
reqStackTrace
reqScopes
reqVariables
reqEvaluate
Content-Length
```

Также:

```text
daslang/main.cpp
```

Искать:

```text
debuggerRequired
policies.debugger
daslib/debug.das
das-wait-debugger
```

---

# 48. Финальная рекомендация для OpenCode/Qwen-подобного агента

Сделать DAP не частью reasoning prompt, а частью tool layer.

Плохой вариант:

```text
LLM:
"сейчас я напишу socket client, попробую JSON..."
```

Хороший вариант:

```text
LLM:
das.breakpoint("/src/main.das", 417)
das.continue()
das.stack()
das.locals()
das.evaluate("runtime")
native.break("m3_ParseModule")
native.continue()
native.backtrace()
```

То есть debugger должен стать таким же постоянным механизмом агента, как shell, git и filesystem.

Тогда агент сможет реально использовать его на практике, а не каждый раз заново разбираться, что такое DAP.
