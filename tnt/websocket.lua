--- WebSocket (RFC 6455): сервер на маршруте `tnt-router` и клиент.
---
--- Сервер — обработчик маршрута. Рукопожатие проходит роутер как обычный
--- запрос: слои входа, журнал, вход по куке, параметры пути. Согласие —
--- ответ 101, после которого роутер отдаёт соединение сессии; отказ —
--- по договору границы HTTP, и роутер рисует его как всякий отказ.
---
---     local websocket = require('tnt.websocket')
---
---     router.get('/ws/echo', websocket.handler(function(ws, request)
---         while true do
---             local message, err = ws:receive()
---
---             if message == nil then
---                 return                         -- закрыто: err.code, err.reason
---             end
---
---             ws:send(message.data, message.kind)
---         end
---     end, { protocols = { 'echo.v1' } }))
---
--- Сессии, которые надо уметь закрыть, держит конечная точка — `endpoint`:
---
---     local chat = websocket.endpoint(talk)
---
---     router.get('/ws/chat', chat.handler)
---     …
---     chat:close_all(websocket.GOING_AWAY, 'узел уходит')   -- перед httpd:stop()
---
--- Клиент — `connect`:
---
---     local ws, err = websocket.connect('wss://example.org/ws/echo', { timeout = 5 })
---
---     ws:send('привет')
---     local message = ws:receive(5)
---     ws:close()
---
--- Сжатие сообщений `permessage-deflate` (RFC 7692) включает настройка
--- `compress` с обеих сторон: сервер принимает предложение клиента,
--- клиент его делает. О чём договорились, видно по `ws.compressed`.
---
--- Отказ — пара `nil, err`: закрытое соединение, молчание дольше срока,
--- непринятое рукопожатие. Негодный аргумент и негодная настройка — бросок
--- на строке вызывающего.

local codes = require('tnt.websocket.codes')
local client = require('tnt.websocket.client')
local connection = require('tnt.websocket.connection')
local failure = require('tnt.websocket.failure')
local must = require('tnt.must')
local server = require('tnt.websocket.server')
local settings_of = require('tnt.websocket.settings')

local Module = {}

--- Коды закрытия (RFC 6455, §7.4).
Module.NORMAL = codes.NORMAL
Module.GOING_AWAY = codes.GOING_AWAY
Module.PROTOCOL_ERROR = codes.PROTOCOL_ERROR
Module.UNSUPPORTED_DATA = codes.UNSUPPORTED_DATA
Module.NO_STATUS = codes.NO_STATUS
Module.ABNORMAL = codes.ABNORMAL
Module.INVALID_DATA = codes.INVALID_DATA
Module.POLICY_VIOLATION = codes.POLICY_VIOLATION
Module.MESSAGE_TOO_BIG = codes.MESSAGE_TOO_BIG
Module.MANDATORY_EXTENSION = codes.MANDATORY_EXTENSION
Module.INTERNAL_ERROR = codes.INTERNAL_ERROR
Module.SERVICE_RESTART = codes.SERVICE_RESTART
Module.TRY_AGAIN_LATER = codes.TRY_AGAIN_LATER

--- Виды сообщений.
Module.TEXT = connection.TEXT
Module.BINARY = connection.BINARY

--- Роды отказа.
Module.CLOSED = failure.CLOSED
Module.TIMEOUT = failure.TIMEOUT
Module.INVALID = failure.INVALID
Module.REFUSED = failure.REFUSED
Module.UNREACHABLE = failure.UNREACHABLE

---@class TntWebsocketOptions
---@field max_message integer|nil Сколько байт в сообщении принять; по умолчанию мегабайт
---@field ping_interval number|nil Сколько секунд молчания до ping; по умолчанию 30
---@field send_timeout number|nil Срок очереди записи и записи кадра; по умолчанию 10 с
---@field close_timeout number|nil Сколько ждать ответа на закрытие; по умолчанию 5 с
---@field backlog integer|nil Сколько непрочитанных сообщений держать; по умолчанию 16
---@field compress boolean|nil Принимать ли сжатие permessage-deflate; по умолчанию нет
---@field protocols string[]|nil Подпротоколы сервера в порядке предпочтения
---@field origins string[]|nil Разрешённые источники страниц; по умолчанию — только свой
---@field max_connections integer|nil Сколько сессий этого маршрута держать разом

---@class TntWebsocketClientOptions
---@field max_message integer|nil
---@field ping_interval number|nil
---@field send_timeout number|nil
---@field close_timeout number|nil
---@field backlog integer|nil
---@field compress boolean|nil Предлагать ли серверу сжатие permessage-deflate; по умолчанию нет
---@field protocols string[]|nil Подпротоколы, которые предложить серверу
---@field origin string|nil Заголовок Origin
---@field headers table<string, string>|nil Свои заголовки рукопожатия
---@field timeout number|nil Срок на соединение, TLS и рукопожатие; по умолчанию 10 с
---@field verify boolean|nil Проверять ли сертификат у wss; выключается только словом false
---@field ca_file string|nil Файл доверенных корней
---@field ca_path string|nil Каталог доверенных корней

--- Конечная точка: обработчик маршрута `handler` вместе с его сессиями.
---
--- Сессия — функция `(ws, request)`: соединение и запрос рукопожатия
--- (с параметрами пути и всем, что положили в него слои). Соединение живёт,
--- пока она идёт; вернулась — закрыто кодом 1000, упала — кодом 1011.
---
--- Сессии конечная точка помнит: `count()` — сколько их идёт,
--- `close_all(code, reason)` — закрыть все, скажем кодом 1001 перед
--- остановкой сервера. Приложение, которое принимает на маршрут конечную
--- точку целиком, а не один `handler`, может закрывать её сессии само,
--- когда отключает роутер.
---@param session fun(ws: TntWebsocketConnection, request: table)
---@param opts TntWebsocketOptions|nil
---@return TntWebsocketEndpoint
function Module.endpoint(session, opts)
    must.at(2).callable(session, 'сессия WebSocket')

    return server.endpoint(session, settings_of.server(opts))
end

--- Обработчик маршрута: рукопожатие и сессия на каждое соединение.
---
--- Та же конечная точка без средств над сессиями — для маршрута,
--- которому закрывать их некому и незачем.
---@param session fun(ws: TntWebsocketConnection, request: table)
---@param opts TntWebsocketOptions|nil
---@return fun(request: table): table|nil, TntWebsocketFailure|nil
function Module.handler(session, opts)
    must.at(2).callable(session, 'сессия WebSocket')

    return server.endpoint(session, settings_of.server(opts)).handler
end

--- Соединяется с сервером WebSocket.
---@param url string ws:// либо wss://
---@param opts TntWebsocketClientOptions|nil
---@return TntWebsocketConnection|nil ws
---@return TntWebsocketFailure|nil err `unreachable` либо `refused`
function Module.connect(url, opts)
    must.at(2).string(url, 'адрес WebSocket')

    local address = client.address_of(url)
    local settings = settings_of.client(opts)
    local ws, err = client.connect(address, settings)

    return ws, err
end

return Module
