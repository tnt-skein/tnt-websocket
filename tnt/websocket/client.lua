--- Клиент WebSocket: соединение с чужим сервером по `ws://` и `wss://`.
---
--- Соединение, TLS и рукопожатие идут одним сроком `timeout`: миг срока
--- отмечается настоящими часами при вызове, остаток каждого ожидания
--- считается от времени планировщика — правило сроков `tnt-clock`.
--- Отказ — пара: `unreachable`, если до сервера не дошли, `refused`,
--- если он не принял рукопожатие или ответил не по RFC 6455.
---
--- Ответ сервера сверяется строго: 101, `Upgrade` и `Connection`, ответ
--- на наш ключ, подпротокол — из предложенных. Расширение — только
--- `permessage-deflate` и только если мы его предложили (`compress`),
--- с параметрами по RFC 7692 (`tnt.websocket.deflate`): кадры с чужим
--- расширением мы не прочли бы.

local digest = require('digest')
local errno = require('errno')
local socket_of = require('socket')

local clock = require('tnt.clock')
local external = require('tnt.external')
local tls = require('tnt.tls')

local connection_of = require('tnt.websocket.connection')
local deflate_of = require('tnt.websocket.deflate')
local failure = require('tnt.websocket.failure')
local handshake = require('tnt.websocket.handshake')
local wire = require('tnt.websocket.wire')

local Module = {}

--- Внешние средства: сеть, шифрование, случайность ключа и часы.
---
--- Прямые ссылки на готовое: OpenSSL `tnt-tls` грузит при первом
--- шифровании, а не при подключении модуля.
local source = external.install(Module, {
    connect = socket_of.tcp_connect,
    secure = tls.wrap,
    random = digest.urandom,
    monotonic = clock.monotonic,
    scheduler_now = clock.scheduler_now,
})

--- Сколько байт головы ответа читать, не больше.
local MAX_HEAD = 16 * 1024

--- Конец головы ответа.
local END_OF_HEAD = '\r\n\r\n'

--- Порты по умолчанию.
local PORTS = { ws = 80, wss = 443 }

---@class TntWebsocketAddress
---@field secure boolean wss
---@field host string Узел без скобок
---@field port integer
---@field authority string Узел и порт, как их пишут в `Host`
---@field resource string Путь со строкой запроса

--- Разбирает адрес WebSocket.
---
--- Негодный адрес — ошибка программиста: схема не `ws`/`wss`, нет узла,
--- порт не числом, учётка в адресе или обрывок после решётки (§3 RFC 6455
--- их запрещает). Бросок — на строке того, кто позвал фасад.
---@param url string
---@return TntWebsocketAddress
function Module.address_of(url)
    -- Повторы в образцах — `XX*`, а не `X+`: у якоря и у знака, которого
    -- в наборе нет, ленивый `X-` совпадает с жадным, и мутант повтора
    -- был бы неотличим. Схема — ровно `ws` либо `wss` в любом регистре.
    local scheme, authority, resource = tostring(url):match('^([wW][sS][sS]?)://([^/?#][^/?#]*)([^#]*)$')
    local port = scheme and PORTS[scheme:lower()]

    if port == nil or tostring(authority):find('@') ~= nil then
        error(
            ('адрес WebSocket — ws://узел[:порт]/путь или wss://…, а не %q'):format(
                tostring(url)
            ),
            3
        )
    end

    ---@cast scheme string
    ---@cast authority string
    ---@cast resource string

    local host, given = authority:match('^%[(.+)%]:?(%d*)$')

    if host == nil then
        host, given = authority:match('^([^:][^:]*):?(%d*)$')
    end

    if host == nil then
        error(('в адресе WebSocket негодный узел или порт: %q'):format(url), 3)
    end

    if resource:sub(-#resource, 1) ~= '/' then
        resource = '/' .. resource
    end

    return {
        secure = scheme:lower() == 'wss',
        host = host --[[@as string]],
        port = (tonumber(given) or port) --[[@as integer]],
        authority = authority,
        resource = resource,
    }
end

--- Запрос рукопожатия (§4.1).
---@param address TntWebsocketAddress
---@param key string
---@param settings table
---@return string
local function greeting(address, key, settings)
    local lines = {
        ('GET %s HTTP/1.1'):format(address.resource),
        ('Host: %s'):format(address.authority),
        'Upgrade: websocket',
        'Connection: Upgrade',
        ('Sec-WebSocket-Key: %s'):format(key),
        ('Sec-WebSocket-Version: %s'):format(handshake.VERSION),
    }

    if settings.protocols ~= nil then
        table.insert(lines, ('Sec-WebSocket-Protocol: %s'):format(table.concat(settings.protocols, ', ')))
    end

    if settings.compress then
        table.insert(lines, ('Sec-WebSocket-Extensions: %s'):format(deflate_of.OFFER))
    end

    if settings.origin ~= nil then
        table.insert(lines, ('Origin: %s'):format(settings.origin))
    end

    local names = {}

    for name in pairs(settings.headers) do
        table.insert(names, name)
    end

    table.sort(names)

    for _, name in ipairs(names) do
        table.insert(lines, ('%s: %s'):format(name, settings.headers[name]))
    end

    return table.concat(lines, '\r\n') .. END_OF_HEAD
end

--- Отказ рукопожатия.
---@param message string
---@param status integer|nil
---@return TntWebsocketFailure
local function refused(message, status)
    return failure.new(failure.REFUSED, message, { status = status })
end

--- Сжатие по ответу сервера.
---
--- Заголовка нет — сжатия нет. Есть, а мы сжатия не предлагали, либо
--- ответ не по RFC 7692 — отказ: договор, о котором не договаривались,
--- портит поток с первого кадра.
---@param value string|nil Заголовок `Sec-WebSocket-Extensions` ответа
---@param settings table
---@param status integer
---@return TntWebsocketDeflate|nil deflate
---@return TntWebsocketFailure|nil err
local function negotiated(value, settings, status)
    if value == nil then
        return nil
    end

    if not settings.compress then
        return nil,
            refused('сервер включил расширение, которого не просили', status)
    end

    local deflate = deflate_of.agreed(value)

    if deflate == nil then
        return nil,
            refused(
                ('сервер ответил на permessage-deflate не по RFC 7692: %s'):format(value),
                status
            )
    end

    return deflate
end

---@class TntWebsocketAgreed То, о чём договорились в рукопожатии
---@field protocol string|nil Подпротокол
---@field deflate TntWebsocketDeflate|nil Договор о сжатии

--- Сверяет голову ответа сервера и отдаёт, о чём договорились.
---@param head string
---@param key string
---@param settings table
---@return TntWebsocketAgreed|nil agreed nil — отказ
---@return TntWebsocketFailure|nil err
function Module.verified(head, key, settings)
    local status = tonumber(head:match('^HTTP/1%.1 (%d%d%d)')) --[[@as integer|nil]]

    if status == nil then
        return nil, refused('сервер ответил не по HTTP/1.1')
    end

    if status ~= 101 then
        return nil, refused(('сервер не принял рукопожатие: %d'):format(status), status)
    end

    ---@type table<string, string>
    local headers = {}

    -- Построчно и по первому двоеточию: значение (`Location: http://…`)
    -- двоеточия тоже несёт. Строка статуса двоеточия не несёт.
    for _, line in ipairs(head:split('\r\n')) do
        local colon = line:find(':')

        if colon ~= nil then
            headers[line:sub(-#line, colon - 1):lower()] = line:sub(colon + 1):match('^[ \t]*(.-)[ \t]*$')
        end
    end

    if not (handshake.names(headers.upgrade, 'websocket') and handshake.names(headers.connection, 'upgrade')) then
        return nil, refused('сервер ответил 101 без Upgrade: websocket и Connection: Upgrade', status)
    end

    if headers['sec-websocket-accept'] ~= handshake.accept_of(key) then
        return nil,
            refused(
                'сервер ответил не на наш ключ: Sec-WebSocket-Accept не сходится',
                status
            )
    end

    local deflate, refusal = negotiated(headers['sec-websocket-extensions'], settings, status)

    if refusal ~= nil then
        return nil, refusal
    end

    local protocol = headers['sec-websocket-protocol']

    if protocol == nil then
        return { deflate = deflate }
    end

    for _, offered in ipairs(settings.protocols or {}) do
        if offered == protocol then
            return { protocol = protocol, deflate = deflate }
        end
    end

    return nil,
        refused(
            ('сервер выбрал подпротокол, которого не предлагали: %s'):format(
                protocol
            ),
            status
        )
end

--- Открывает сокет и, у `wss`, поднимает TLS.
---@param address TntWebsocketAddress
---@param settings table
---@param left fun(): number Остаток срока
---@return TntWebsocketWire|nil link
---@return TntWebsocketFailure|nil err
local function reach(address, settings, left)
    local socket = source().connect(address.host, address.port, left())
    local where = ('%s:%d'):format(address.host, address.port)

    if socket == nil then
        -- Причину `tcp_connect` оставляет в errno — спрашивать сразу,
        -- пока её не перебил следующий вызов ядра.
        local why = errno.strerror()

        return nil,
            failure.new(
                failure.UNREACHABLE,
                ('соединение с %s не открылось: %s'):format(where, why)
            )
    end

    if not address.secure then
        return wire.of(socket)
    end

    local link, refusal = source().secure(socket, {
        host = address.host,
        timeout = left(),
        verify = settings.verify,
        ca_file = settings.ca_file,
        ca_path = settings.ca_path,
    })

    if link == nil then
        -- При неудачном рукопожатии TLS сокет остаётся нам: так договор
        -- `tnt-tls`.
        pcall(socket.close, socket)

        return nil,
            failure.new(failure.UNREACHABLE, ('TLS с %s не поднялся: %s'):format(where, tostring(refusal)))
    end

    return link
end

--- Соединяется с сервером WebSocket.
---@param address TntWebsocketAddress Разобранный адрес
---@param settings TntWebsocketClientSettings Проверенные настройки клиента
---@return TntWebsocketConnection|nil connection
---@return TntWebsocketFailure|nil err
function Module.connect(address, settings)
    local clocks = source()
    local deadline = clocks.monotonic() + settings.timeout

    local function left()
        return deadline - clocks.scheduler_now()
    end

    local link, refusal = reach(address, settings, left)

    if link == nil then
        return nil, refusal
    end

    local key = digest.base64_encode(clocks.random(16))
    local written, why = link:write(greeting(address, key, settings), left())
    local head = written and link:read({ delimiter = END_OF_HEAD, chunk = MAX_HEAD }, left())

    if not head or head:sub(-#END_OF_HEAD) ~= END_OF_HEAD then
        link:close()

        return nil,
            refused(
                ('сервер не ответил на рукопожатие за срок: %s'):format(
                    tostring(why or 'голова ответа не пришла целиком')
                )
            )
    end

    local agreed, err = Module.verified(head, key, settings)

    if agreed == nil then
        link:close()

        return nil, err
    end

    return connection_of.new(link, {
        masking = true,
        owned = true,
        settings = settings,
        protocol = agreed.protocol,
        deflate = agreed.deflate,
    })
end

return Module
