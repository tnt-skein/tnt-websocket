# tnt-websocket

WebSocket (RFC 6455) для Tarantool: сервер на маршруте роутера
`tnt-router` и клиент `ws://` и `wss://`. Рукопожатие — обычный запрос
роутера со слоями, журналом и отказом по договору границы HTTP, кадры —
строго по RFC 6455, сжатие сообщений — по RFC 7692, отказ — пара `nil, err`.

```lua
local router = require('tnt.router')
local websocket = require('tnt.websocket')

router.get('/ws/:room', websocket.handler(function(ws, request)
    ws:send('вы в комнате ' .. request.params.room)

    while true do
        local message = ws:receive()

        if message == nil then
            return                              -- закрыто: код и причина — во втором значении
        end

        ws:send(message.data, message.kind)     -- эхо
    end
end, { protocols = { 'echo.v1' } }))

local httpd = require('http.server').new('127.0.0.1', 8080, { log_requests = false, idle_timeout = 60 })

router.attach(httpd)
httpd:start()

local ws = websocket.connect('ws://127.0.0.1:8080/ws/kitchen', { protocols = { 'echo.v1' }, timeout = 5 })

ws:receive(5)                                   --> { kind = 'text', data = 'вы в комнате kitchen' }
ws:send('привет')                               --> true
ws:receive(5)                                   --> { kind = 'text', data = 'привет' }
ws:close()                                      --> true
```

Зависимости: `tnt-must` (проверки аргументов), `tnt-clock` (сроки),
`tnt-context` (сессия в контексте запроса), `tnt-hash` (SHA-1 ответа
на ключ), `tnt-log` (журнал), `tnt-external` (подмена внешних средств
в проверках), `tnt-tls` (клиент `wss://`) и `tnt-compress` (сжатие
сообщений). Роутер зависимостью
не объявлен: ответ 101 — таблица с полем `takeover`, а соединение сессии
отдаёт подключение роутера.

## Зачем

У Tarantool 3.8 CE WebSocket нет ни в ядре, ни среди официальных роков,
а `http.server` соединение из рук не выпускает: после ответа он ждёт
на нём следующий запрос HTTP. Пакет даёт WebSocket на том же сервере
и тех же маршрутах, что и страницы:

- **Рукопожатие — запрос роутера.** Слои входа, журнал, опознаватель
  и вход по куке, уже поставленные на маршруты, действуют и на него,
  а отказ — 405, 426, 400, 403, 503 — рисует обработчик отказов роутера.
- **Кадры строго по RFC 6455.** Маска, длины, управляющие кадры, сборка
  частей, UTF-8 текста, коды закрытия; нарушение — разрыв с кодом, а не
  догадка. Кадр длиннее предела не читается вовсе: заявленные гигабайты
  не ложатся в память узла.
- **Живость.** Кадры читает отдельный файбер: отвечает на ping, ведёт
  закрытие рукопожатием и шлёт свой ping после молчания; сторона,
  не ответившая и на него, — обрыв 1006.
- **Защита по умолчанию.** Пускаются только страницы своего узла
  (`Origin` против `Host`), предел сообщения — мегабайт, предел сессий
  маршрута — настройкой.
- **Сессии закрываются разом.** Конечная точка помнит свои сессии
  и закрывает их кодом 1001 перед остановкой сервера — клиенты узнают,
  что пора подключиться заново, а не видят обрыв.
- **Сжатие по желанию.** `permessage-deflate` (RFC 7692) включает
  настройка `compress`: сервер принимает предложение браузера, клиент
  делает его сам; свой словарь держится от сообщения к сообщению,
  разжатое той стороны считается против предела сообщения.

## Установка

```sh
tt rocks install tnt-websocket --server=https://tnt-skein.github.io/rocks
```

Или из исходников:

```sh
git clone https://github.com/tnt-skein/tnt-websocket.git
cd tnt-websocket && tt rocks make
```

## Как пользоваться

| Вызов | Что делает |
|---|---|
| `websocket.handler(session, opts)` | обработчик маршрута: ответ 101 либо отказ парой |
| `websocket.endpoint(session, opts)` | конечная точка: `handler`, `count()`, `close_all(code, reason)` |
| `websocket.connect(url, opts)` | клиент: соединение либо `nil, err` (`unreachable`, `refused`) |
| `ws:receive(timeout)` | сообщение `{ kind, data }`; `nil, err` — закрыто либо срок |
| `ws:send(data, kind)` | сообщение одним кадром; `kind` — `text` (по умолчанию) либо `binary` |
| `ws:close(code, reason)` | свой кадр закрытия и ответ той стороны |
| `ws:is_open()`, `ws.protocol`, `ws.request`, `ws.closed` | открыто ли, подпротокол, запрос рукопожатия, чем кончилось |
| `ws.compressed` | договорились ли о сжатии `permessage-deflate` |

Сессии, которые надо закрыть перед остановкой сервера, держит конечная
точка:

```lua
local chat = websocket.endpoint(function(ws)
    while ws:receive() do end                   -- читает, пока соединение открыто
end)

router.get('/ws/chat', chat.handler)
-- …
chat:count()                                            --> 2
chat:close_all(websocket.GOING_AWAY, 'узел уходит')     --> 2
httpd:stop()
```

Настройки — `max_message`, `ping_interval`, `send_timeout`,
`close_timeout`, `backlog`, `compress`, `protocols`; у сервера ещё `origins`
и `max_connections`, у клиента — `timeout`, `origin`, `headers`
и настройки TLS `verify`, `ca_file`, `ca_path`. Негодная настройка —
бросок на строке, где её дали, а не на первом кадре.

## Проверки

```sh
make deps          # luatest, luacheck, luacov с cluacov, рок http, зависимости пакета и роутер в .rocks
make check         # форматирование, линт, проверки, покрытие с порогом 100 %
make mutants-all   # мутационное тестирование утилитой tnt-mutants из PATH, порог 100 % убитых
```

Покрытие строк — 100 %, убитых мутантов — 100 % (183 проверки; 870 мутантов
в одиннадцати модулях).
Соединение проверяется на настоящей паре сокетов, сервер и клиент
пакета — через `http.server` с настоящим роутером `tnt-router`, а живая
проверка сверяет сервер с клиентом `WebSocket` из Node (без Node она
пропускается).

## Документ

Полное описание с рукопожатием, кадрами, живостью и закрытием,
настройками, клиентом, работой за обратным прокси и обоснованием решений:
[docs/websocket.md](docs/websocket.md).

## Лицензия

MIT.
