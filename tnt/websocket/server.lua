--- Сторона сервера: рукопожатие по запросу роутера и сессия на соединении.
---
--- Рукопожатие — обычный запрос по договору `tnt-router`: маршрут,
--- параметры пути, слои входа и маршрута (журнал, опознаватель, вход по
--- куке) проходят его как всякий другой. Отказ — пара `nil, err` по
--- договору границы HTTP: числовой `status`, слово, заголовки, — и роутер
--- отвечает им, как отказом любого обработчика. Согласие — ответ 101
--- с полем `takeover`: роутер пишет голову ответа и отдаёт соединение
--- сессии (`tnt.router.takeover`).
---
--- Сессия идёт в файбере соединения `http.server` и в контексте запроса
--- рукопожатия (`tnt-context`): записи журнала из неё несут опознаватель
--- запроса, хотя слои, положившие его, к тому времени уже вернулись.
---
--- Конечная точка (`endpoint`) — обработчик маршрута вместе с его
--- сессиями. Сессии помнит она, а не общий на процесс реестр: закрыть
--- их при остановке может тот, кто объявил маршрут, и чужие маршруты
--- при этом не задеты. `httpd:stop()` закрывает только приём новых
--- соединений — идущие сессии закрывает `close_all`.
---
--- О сжатии `permessage-deflate` сервер договаривается, только если
--- его включили (`compress`): принимает первое годное предложение клиента
--- и называет договор в ответе 101 (`tnt.websocket.deflate`). Негодное
--- или незнакомое предложение отказом не бывает — рукопожатие идёт без
--- сжатия, и решать, годится ли это, — клиенту.

local fiber = require('fiber')

local context = require('tnt.context')

local codes = require('tnt.websocket.codes')
local connection_of = require('tnt.websocket.connection')
local deflate_of = require('tnt.websocket.deflate')
local failure = require('tnt.websocket.failure')
local frame = require('tnt.websocket.frame')
local handshake = require('tnt.websocket.handshake')
local wire = require('tnt.websocket.wire')

local log = require('tnt.log').new('tnt.websocket')

local Module = {}

--- Заголовки отказа 426: чем сюда ходить (RFC 9110, §15.5.22) и на какой версии.
local UPGRADE_REQUIRED = { upgrade = 'websocket', ['sec-websocket-version'] = handshake.VERSION }

--- Тексты отказов рукопожатия, которые длиннее строки вызова.
---
--- Вынесены, чтобы вызов со статусом стоял одной строкой: статус на своей
--- строке генератор мутантов не видит, и замена 403 на 404 прошла бы
--- мимо проверок.
local NOT_GET = 'рукопожатие WebSocket идёт только способом GET'
local NOT_UPGRADE = 'сюда ходят по WebSocket: нужны Upgrade: websocket и Connection: Upgrade'
local FOREIGN_ORIGIN =
    'страницам с этого источника соединение не разрешено'
local CROWDED = 'соединений WebSocket больше предела: попробуйте позже'

---@class TntWebsocketLive
---@field count integer Сколько сессий идёт сейчас
---@field connections table<TntWebsocketConnection, TntWebsocketConnection> Соединения идущих сессий

--- Сессии конечной точки: пока ни одной.
---@return TntWebsocketLive
function Module.live()
    return { count = 0, connections = {} }
end

--- Отказ рукопожатия по договору границы HTTP.
---@param status integer
---@param message string
---@param headers table<string, string>|nil
---@return nil
---@return TntWebsocketFailure
local function refused(status, message, headers)
    return nil, failure.new(failure.REFUSED, message, { status = status, headers = headers })
end

--- Пустили бы страницу с этого источника.
---
--- Без заголовка `Origin` ходят не браузеры — им запрет чужих страниц
--- ни к чему. Список не задан — пускается только своё: источник
--- `https://` либо `http://` с тем же узлом, что в `Host`. Иначе любая
--- страница в интернете открыла бы соединение от имени вошедшего
--- оператора: браузер шлёт его куки на рукопожатие с чужой страницы так
--- же, как со своей.
---@param headers table<string, string>
---@param origins string[]|nil
---@return boolean
local function welcome(headers, origins)
    local origin = headers.origin

    if origin == nil then
        return true
    end

    origin = origin:lower()

    if origins == nil then
        local host = tostring(headers.host):lower()

        return origin == 'https://' .. host or origin == 'http://' .. host
    end

    local allowed = false

    for _, name in ipairs(origins) do
        allowed = allowed or name == '*' or name:lower() == origin
    end

    return allowed
end

--- Подпротокол: первый из списка сервера, который предложил клиент.
---
--- Не предложил ни одного из нужных — рукопожатие идёт без подпротокола
--- (§4.2.2): решать, годится ли это, — клиенту и сессии, а не серверу.
---@param offered string|nil Заголовок `Sec-WebSocket-Protocol`
---@param supported string[]|nil
---@return string|nil
local function chosen(offered, supported)
    local asked = {}

    for _, name in ipairs(handshake.listed(offered)) do
        asked[name] = true
    end

    for _, name in ipairs(supported or {}) do
        if asked[name] then
            return name
        end
    end

    return nil
end

---@class TntWebsocketAccepted Принятое рукопожатие
---@field key string Ключ клиента
---@field protocol string|nil Подпротокол
---@field deflate TntWebsocketDeflate|nil Договор о сжатии
---@field extensions string|nil Заголовок `Sec-WebSocket-Extensions` ответа

--- Проверяет запрос рукопожатия.
---@param request table Запрос роутера
---@param settings table Проверенные настройки сервера
---@return TntWebsocketAccepted|nil accepted
---@return TntWebsocketFailure|nil err Отказ со статусом
function Module.check(request, settings)
    local headers = request.headers or {}

    if request.method ~= 'GET' then
        return refused(405, NOT_GET, { allow = 'GET' })
    end

    if not (handshake.names(headers.upgrade, 'websocket') and handshake.names(headers.connection, 'upgrade')) then
        return refused(426, NOT_UPGRADE, UPGRADE_REQUIRED)
    end

    if headers['sec-websocket-version'] ~= handshake.VERSION then
        return refused(426, 'версия WebSocket не та: сервер говорит на 13', UPGRADE_REQUIRED)
    end

    local key = headers['sec-websocket-key']

    if key == nil or key:match(handshake.KEY) == nil then
        return refused(400, 'ключ Sec-WebSocket-Key — не 16 байт в base64')
    end

    if not welcome(headers, settings.origins) then
        return refused(403, FOREIGN_ORIGIN)
    end

    local accepted = { key = key, protocol = chosen(headers['sec-websocket-protocol'], settings.protocols) }

    if settings.compress then
        accepted.deflate, accepted.extensions = deflate_of.accept(headers['sec-websocket-extensions'])
    end

    return accepted
end

--- Полон ли предел сессий.
---@param settings table
---@param live TntWebsocketLive
---@return boolean
local function crowded(settings, live)
    return settings.max_connections ~= nil and live.count >= settings.max_connections
end

--- Ведёт сессию на забранном соединении и закрывает его после неё.
---
--- Сессия, вернувшаяся без закрытия, закрывает соединение кодом 1000;
--- упавшая — кодом 1011, а подробность уходит в журнал, не той стороне.
---@param session fun(connection: TntWebsocketConnection, request: table)
---@param request table
---@param connection TntWebsocketConnection
local function converse(session, request, connection)
    local ok, err = pcall(session, connection, request)

    if ok then
        connection:close()

        return
    end

    log.error('сессия WebSocket упала', { path = request.path, reason = tostring(err) })
    connection:close(codes.INTERNAL_ERROR)
end

--- Ответ на рукопожатие либо отказ.
---
--- Предел сессий сверяется дважды. На рукопожатии — отказом 503, пока
--- ответ ещё не ушёл. И на самом соединении: между ответом и сессией
--- файбер уступает, и два рукопожатия успели бы пройти одну и ту же
--- сверку, — второе тогда закрывается кодом 1013 («попробуйте позже»).
---@param request table Запрос роутера
---@param session fun(connection: TntWebsocketConnection, request: table)
---@param settings table Проверенные настройки сервера
---@param live TntWebsocketLive Счёт сессий этого обработчика
---@return table|nil response Ответ 101 с `takeover`
---@return TntWebsocketFailure|nil err Отказ со статусом
function Module.accept(request, session, settings, live)
    local accepted, refusal = Module.check(request, settings)

    if accepted == nil then
        return nil, refusal
    end

    if crowded(settings, live) then
        return refused(503, CROWDED)
    end

    local takeover = context.bind(function(socket)
        local connection = connection_of.new(wire.of(socket), {
            masking = false,
            owned = false,
            settings = settings,
            protocol = accepted.protocol,
            request = request,
            deflate = accepted.deflate,
        })

        if crowded(settings, live) then
            connection:close(codes.TRY_AGAIN_LATER)

            return
        end

        live.count = live.count + 1
        live.connections[connection] = connection
        converse(session, request, connection)
        live.connections[connection] = nil
        live.count = live.count - 1
    end)

    return {
        status = 101,
        headers = {
            upgrade = 'websocket',
            connection = 'Upgrade',
            ['sec-websocket-accept'] = handshake.accept_of(accepted.key),
            ['sec-websocket-protocol'] = accepted.protocol,
            ['sec-websocket-extensions'] = accepted.extensions,
        },
        takeover = takeover,
    }
end

---@class TntWebsocketEndpoint
---@field handler fun(request: table): table|nil, TntWebsocketFailure|nil Обработчик маршрута
---@field live TntWebsocketLive Сессии, которые идут сейчас
local Endpoint = {}
Endpoint.__index = Endpoint

--- Сколько сессий идёт сейчас.
---@return integer
function Endpoint:count()
    return self.live.count
end

--- Закрывает соединения всех идущих сессий и ждёт, пока они закроются.
---
--- Каждое соединение закрывается в своём файбере: закрытие ждёт ответа
--- той стороны до `close_timeout`, и сотня молчащих клиентов по одному
--- держала бы остановку узла сотню сроков, а разом — один. Соединения,
--- которые уже закрываются, не трогаются: их сессия кончается сама.
---
--- Сессия узнаёт о закрытии на ближайшем `receive` или `send`
--- и возвращается сама; счёт падает, когда она вернулась.
---@param code integer|nil Код закрытия; по умолчанию 1001 — сторона уходит
---@param reason string|nil Причина; по умолчанию пустая
---@return integer closed Сколько соединений закрыто
function Endpoint:close_all(code, reason)
    local closing_code = code or codes.GOING_AWAY
    local said = reason or ''

    frame.check_closing(closing_code, said)

    local closers = {}

    -- Файберы только заводятся, управление не уступается: набор
    -- соединений не меняется посреди обхода. Закрытие идёт в контексте
    -- того, кто закрывает, а не с пустым хранилищем голого файбера.
    for _, connection in pairs(self.live.connections) do
        if connection:is_open() then
            local closer = fiber.new(context.bind(connection.close), connection, closing_code, said)

            closer:set_joinable(true)
            table.insert(closers, closer)
        end
    end

    for _, closer in ipairs(closers) do
        closer:join()
    end

    return #closers
end

--- Конечная точка: обработчик маршрута и его сессии.
---@param session fun(connection: TntWebsocketConnection, request: table)
---@param settings table Проверенные настройки сервера
---@return TntWebsocketEndpoint
function Module.endpoint(session, settings)
    local live = Module.live()

    return setmetatable({
        live = live,
        handler = function(request)
            return Module.accept(request, session, settings, live)
        end,
    }, Endpoint)
end

return Module
