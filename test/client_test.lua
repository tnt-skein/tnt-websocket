--- Тесты клиента: адрес, запрос рукопожатия, сверка ответа, сроки и TLS.
---
--- Сервер здесь — сырой `tcp_server` на петле, отвечающий заготовленной
--- головой: так видно, что именно клиент послал, и каждый негодный ответ
--- пишется руками. Разговор с настоящим сервером пакета — в `websocket_test.lua`.

local t = require('luatest')

local digest = require('digest')
local fiber = require('fiber')
local socket = require('socket')

local helper = dofile('test/helper.lua')

local g = t.group('tnt.websocket.client')

local client = helper.client
local frame = helper.frame
local websocket = helper.websocket

--- Шестнадцать байт ключа, у которых ответ известен из RFC.
local SAMPLE_BYTES = digest.base64_decode(helper.SAMPLE_KEY)

--- Годная голова ответа на ключ из RFC.
---@param extra string|nil Строки заголовков сверх обязательных
---@return string
local function switching(extra)
    return 'HTTP/1.1 101 Switching Protocols\r\n'
        .. 'Upgrade: websocket\r\n'
        .. 'Connection: Upgrade\r\n'
        .. ('Sec-WebSocket-Accept: %s\r\n'):format(helper.SAMPLE_ACCEPT)
        .. (extra or '')
        .. '\r\n'
end

g.before_each(function()
    client._set_source({
        random = function(size)
            t.assert_equals(size, 16)

            return SAMPLE_BYTES
        end,
    })
end)

g.after_each(function()
    helper.restore()
end)

---@class TntWebsocketFakeServer
---@field port integer
---@field heads string[] Головы запросов, по порядку
---@field peers any[] Сокеты соединений
---@field stop fun()

--- Сырой сервер: читает голову запроса и отвечает заготовленным.
---@param answer string|fun(peer: table)|nil Что ответить; функция говорит сама; nil — молчать
---@return TntWebsocketFakeServer
local function serve(answer)
    local fake = { heads = {}, peers = {} }
    -- Соединение живёт до конца проверки: сокет закрывает сам `tcp_server`,
    -- когда обработчик вернулся. Читать из сокета обработчику нельзя —
    -- проверка читает оттуда кадры клиента сама.
    local release = fiber.channel()

    local listener = socket.tcp_server('127.0.0.1', 0, function(peer)
        table.insert(fake.peers, peer)
        table.insert(fake.heads, peer:read({ delimiter = '\r\n\r\n' }, 5))

        if type(answer) == 'function' then
            answer(peer)
        elseif answer ~= nil then
            peer:write(answer)
        end

        release:get(5)
    end)

    fake.port = listener:name().port --[[@as integer]]

    fake.stop = function()
        listener:close()
        release:close()
    end

    return fake
end

--- Разбор адреса, как его зовёт фасад.
---
--- Бросок `address_of` показывает на кадр выше вызвавшего — у фасада это
--- его вызывающий. Проверка зовёт через эту функцию, и не хвостовым
--- вызовом: иначе бросок под мутантом показал бы на раннер luatest,
--- и мутационный гейт принял бы его за отказ запуска проверок.
---@param url string
---@return TntWebsocketAddress
local function address(url)
    local parsed = client.address_of(url)

    return parsed
end

g.test_address_is_split_into_what_the_connection_needs = function()
    t.assert_equals(address('ws://example.org'), {
        secure = false,
        host = 'example.org',
        port = 80,
        authority = 'example.org',
        resource = '/',
    })
    t.assert_equals(address('WSS://Example.org:8443/chat?room=1'), {
        secure = true,
        host = 'Example.org',
        port = 8443,
        authority = 'Example.org:8443',
        resource = '/chat?room=1',
    })
    t.assert_equals(address('wss://example.org'), {
        secure = true,
        host = 'example.org',
        port = 443,
        authority = 'example.org',
        resource = '/',
    })
    t.assert_equals(address('ws://[::1]:9000/x'), {
        secure = false,
        host = '::1',
        port = 9000,
        authority = '[::1]:9000',
        resource = '/x',
    })
    t.assert_equals(address('ws://[::1]').port, 80)
    t.assert_equals(address('Ws://h').authority, 'h')
    t.assert_equals(address('wSs://h:1/').host, 'h')
    t.assert_equals(address('ws://host?x=1').resource, '/?x=1')
    t.assert_equals(address('ws://host:').port, 80)
end

g.test_wrong_address_blames_the_caller = function()
    local scheme = 'адрес WebSocket — ws://узел[:порт]/путь или wss://…, а не "%s"'

    helper.assert_blamed({
        {
            function()
                websocket.connect('http://example.org/')
            end,
            scheme:format('http://example.org/'),
        },
        {
            function()
                websocket.connect('ws://user@example.org/')
            end,
            scheme:format('ws://user@example.org/'),
        },
        {
            function()
                websocket.connect('ws://example.org/#frag')
            end,
            scheme:format('ws://example.org/#frag'),
        },
        {
            function()
                websocket.connect('ws://')
            end,
            scheme:format('ws://'),
        },
        {
            function()
                websocket.connect('wsss://example.org/')
            end,
            scheme:format('wss' .. 's://example.org/'),
        },
        {
            function()
                websocket.connect('w://example.org/')
            end,
            scheme:format('w://example.org/'),
        },
        {
            function()
                websocket.connect('ws:///chat')
            end,
            scheme:format('ws:///chat'),
        },
        {
            function()
                websocket.connect('ws://:8080/')
            end,
            'в адресе WebSocket негодный узел или порт: "ws://:8080/"',
        },
        {
            function()
                websocket.connect('ws://example.org:http/')
            end,
            'в адресе WebSocket негодный узел или порт: "ws://example.org:http/"',
        },
        {
            function()
                websocket.connect(helper.wrong(80))
            end,
            'адрес WebSocket — строка, а не число',
        },
    })
end

--- Отказ сверки головы ответа.
---@param head string
---@param settings table|nil
---@return TntWebsocketFailure
local function refused(head, settings)
    local agreed, err = client.verified(head, helper.SAMPLE_KEY, settings or {})

    t.assert_equals(agreed, nil)
    t.assert_equals(err.kind, 'refused')

    return err
end

g.test_good_answer_gives_the_protocol_or_none = function()
    t.assert_equals(client.verified(switching(), helper.SAMPLE_KEY, {}), {})
    t.assert_equals(
        client.verified(
            switching('Sec-WebSocket-Protocol: chat\r\n'),
            helper.SAMPLE_KEY,
            { protocols = { 'x', 'chat' } }
        ),
        { protocol = 'chat' }
    )
    -- Имена заголовков — без оглядки на регистр, пробелы вокруг значения — любые,
    -- а двоеточие в значении — часть значения.
    local loose = 'HTTP/1.1 101 OK\r\nupgrade:WebSocket\r\nCONNECTION: \tupgrade  \r\n'
        .. 'X-Where: http://a:1/\r\n'
        .. ('sec-websocket-accept: %s\r\n'):format(helper.SAMPLE_ACCEPT)
        .. 'Sec-WebSocket-Protocol:chat \r\n\r\n'

    t.assert_equals(client.verified(loose, helper.SAMPLE_KEY, { protocols = { 'chat' } }), { protocol = 'chat' })
end

g.test_answers_that_are_not_an_agreement_are_refusals = function()
    t.assert_equals(refused('HTTP/1.0 101 Switching\r\n\r\n').message, 'сервер ответил не по HTTP/1.1')
    t.assert_equals(refused('SSH-2.0-OpenSSH\r\n\r\n').status, nil)

    local forbidden = refused('HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\n\r\n')

    t.assert_equals(
        { forbidden.status, forbidden.message },
        { 403, 'сервер не принял рукопожатие: 403' }
    )

    local cases = {
        {
            'HTTP/1.1 101 Switching Protocols\r\nConnection: Upgrade\r\n'
                .. ('Sec-WebSocket-Accept: %s\r\n\r\n'):format(helper.SAMPLE_ACCEPT),
            'сервер ответил 101 без Upgrade: websocket и Connection: Upgrade',
        },
        {
            'HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n'
                .. ('Sec-WebSocket-Accept: %s\r\n\r\n'):format(helper.SAMPLE_ACCEPT),
            'сервер ответил 101 без Upgrade: websocket и Connection: Upgrade',
        },
        {
            'HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n'
                .. 'Sec-WebSocket-Accept: xxx=\r\n\r\n',
            'сервер ответил не на наш ключ: Sec-WebSocket-Accept не сходится',
        },
        {
            switching('Sec-WebSocket-Extensions: permessage-deflate\r\n'),
            'сервер включил расширение, которого не просили',
        },
        {
            switching('Sec-WebSocket-Protocol: other\r\n'),
            'сервер выбрал подпротокол, которого не предлагали: other',
        },
    }

    for _, case in ipairs(cases) do
        local err = refused(case[1], { protocols = { 'chat' } })

        t.assert_equals({ err.status, err.message }, { 101, case[2] })
    end

    t.assert_equals(refused(switching('Sec-WebSocket-Protocol: chat\r\n')).status, 101)
end

g.test_handshake_request_says_everything_the_rfc_asks = function()
    local fake = serve(switching('Sec-WebSocket-Protocol: chat\r\n'))
    local ws = websocket.connect(('ws://127.0.0.1:%d/chat?room=7'):format(fake.port), {
        protocols = { 'chat', 'json' },
        origin = 'https://panel.example.org',
        headers = { ['x-token'] = 'abc', authorization = 'Bearer 1' },
        close_timeout = 0.05,
    })

    t.assert_equals(
        fake.heads[1],
        'GET /chat?room=7 HTTP/1.1\r\n'
            .. ('Host: 127.0.0.1:%d\r\n'):format(fake.port)
            .. 'Upgrade: websocket\r\n'
            .. 'Connection: Upgrade\r\n'
            .. ('Sec-WebSocket-Key: %s\r\n'):format(helper.SAMPLE_KEY)
            .. 'Sec-WebSocket-Version: 13\r\n'
            .. 'Sec-WebSocket-Protocol: chat, json\r\n'
            .. 'Origin: https://panel.example.org\r\n'
            .. 'authorization: Bearer 1\r\n'
            .. 'x-token: abc\r\n'
            .. '\r\n'
    )
    t.assert_equals(ws.protocol, 'chat')
    t.assert_equals(ws:is_open(), true)
    ws:close()
    fake.stop()
end

g.test_bare_handshake_request_has_only_the_required_headers = function()
    local fake = serve(switching())
    local ws = websocket.connect(('ws://127.0.0.1:%d'):format(fake.port), { close_timeout = 0.05 })

    t.assert_equals(
        fake.heads[1],
        ('GET / HTTP/1.1\r\nHost: 127.0.0.1:%d\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n'):format(fake.port)
            .. ('Sec-WebSocket-Key: %s\r\nSec-WebSocket-Version: 13\r\n\r\n'):format(helper.SAMPLE_KEY)
    )
    t.assert_equals(ws.protocol, nil)
    ws:close()
    fake.stop()
end

g.test_connected_client_talks_in_frames = function()
    local fake = serve(function(peer)
        -- Кадр сервера приходит одним куском с головой ответа: он обязан
        -- остаться в буфере сокета, а не пропасть вместе с ней.
        peer:write(switching() .. helper.plain(frame.TEXT, 'здравствуй'))
    end)
    local ws = websocket.connect(('ws://127.0.0.1:%d/'):format(fake.port), { close_timeout = 0.05 })

    t.assert_equals(ws:receive(1), { kind = 'text', data = 'здравствуй' })
    t.assert_equals(ws:send('ответ'), true)

    local got = frame.read(helper.wire.of(fake.peers[1]), { masked = true, room = 1024, idle = 1, timeout = 1 })

    t.assert_equals(got.payload, 'ответ')
    ws:close()

    -- Сокет клиента закрыт: после кадра закрытия — конец потока.
    local peer = fake.peers[1] --[[@as table]]
    local closing = frame.read(helper.wire.of(peer), { masked = true, room = 1024, idle = 1, timeout = 1 })

    t.assert_equals(closing.opcode, frame.CLOSE)
    t.assert_equals(peer:read(1, 1), '')
    fake.stop()
end

g.test_head_of_exactly_sixteen_kilobytes_is_read_and_one_byte_more_is_not = function()
    local base = switching()
    local pad = 'X-Pad: ' .. string.rep('p', 16 * 1024 - #base - 9) .. '\r\n'
    local exact = switching(pad)

    t.assert_equals(#exact, 16 * 1024)

    local fake = serve(exact)
    local ws = websocket.connect(('ws://127.0.0.1:%d/'):format(fake.port), { close_timeout = 0.05 })

    t.assert_equals(ws:is_open(), true)
    ws:close()
    fake.stop()

    local longer = serve(switching('X-Pad: p' .. pad:sub(8)))
    local refused_ws, err = websocket.connect(('ws://127.0.0.1:%d/'):format(longer.port), { timeout = 1 })

    t.assert_equals(refused_ws, nil)
    t.assert_equals(
        err.message,
        'сервер не ответил на рукопожатие за срок: голова ответа не пришла целиком'
    )
    longer.stop()
end

g.test_refused_handshake_closes_the_socket = function()
    local fake = serve('HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n')
    local ws, err = websocket.connect(('ws://127.0.0.1:%d/'):format(fake.port))

    t.assert_equals(ws, nil)
    t.assert_equals({ err.kind, err.status }, { 'refused', 404 })
    t.assert_equals((fake.peers[1] --[[@as table]]):read(1, 1), '')
    fake.stop()
end

g.test_silent_server_is_a_refusal_within_the_timeout = function()
    local fake = serve(nil)
    local started = require('clock').monotonic()
    local ws, err = websocket.connect(('ws://127.0.0.1:%d/'):format(fake.port), { timeout = 0.2 })

    t.assert_equals(ws, nil)
    t.assert_equals(err.kind, 'refused')
    t.assert_equals(
        err.message,
        'сервер не ответил на рукопожатие за срок: голова ответа не пришла целиком'
    )
    t.assert_lt(require('clock').monotonic() - started, 1)
    fake.stop()
end

g.test_endless_head_is_cut_at_its_limit = function()
    local fake = serve(string.rep('x', 20000))
    local ws, err = websocket.connect(('ws://127.0.0.1:%d/'):format(fake.port), { timeout = 2 })

    t.assert_equals(ws, nil)
    t.assert_equals(
        err.message,
        'сервер не ответил на рукопожатие за срок: голова ответа не пришла целиком'
    )
    fake.stop()
end

g.test_closed_port_is_unreachable = function()
    local listener = socket.tcp_server('127.0.0.1', 0, function() end)
    local port = listener:name().port

    listener:close()

    local ws, err = websocket.connect(('ws://127.0.0.1:%d/'):format(port), { timeout = 1 })

    t.assert_equals(ws, nil)
    t.assert_equals(err.kind, 'unreachable')
    t.assert_equals(
        err.message,
        ('соединение с 127.0.0.1:%d не открылось: Connection refused'):format(port)
    )
end

--- Сокет-двойник: запись не удаётся, ошибка — как у ядра.
---@return table
local function broken_socket()
    local double = { closed = false }

    function double.write()
        return nil
    end

    function double.error()
        return 'Broken pipe'
    end

    function double.close()
        double.closed = true
    end

    return double
end

g.test_request_that_did_not_go_is_a_refusal_with_the_reason = function()
    local double = broken_socket()

    client._set_source({
        random = function()
            return SAMPLE_BYTES
        end,
        connect = function()
            return double
        end,
    })

    local ws, err = websocket.connect('ws://example.org/')

    t.assert_equals(ws, nil)
    t.assert_equals(
        err.message,
        'сервер не ответил на рукопожатие за срок: Broken pipe'
    )
    t.assert_equals(double.closed, true)
end

g.test_one_deadline_covers_connect_tls_and_handshake = function()
    local asked = {}
    local fake = serve(switching())

    client._set_source({
        random = function()
            return SAMPLE_BYTES
        end,
        monotonic = function()
            return 1000
        end,
        scheduler_now = function()
            return 997
        end,
        connect = function(host, port, timeout)
            table.insert(asked, { host, port, timeout })

            return socket.tcp_connect('127.0.0.1', fake.port)
        end,
        secure = function(raw, opts)
            table.insert(asked, opts)

            return helper.wire.of(raw)
        end,
    })

    local ws = websocket.connect('wss://example.org:9443/', {
        timeout = 5,
        verify = false,
        ca_file = '/etc/ca.pem',
        ca_path = '/etc/ca',
        close_timeout = 0.05,
    })

    -- Миг срока — 1000 + 5, остаток — от времени планировщика: 1005 − 997.
    t.assert_equals(asked, {
        { 'example.org', 9443, 8 },
        { host = 'example.org', timeout = 8, verify = false, ca_file = '/etc/ca.pem', ca_path = '/etc/ca' },
    })
    t.assert_equals(ws:is_open(), true)
    ws:close()
    fake.stop()
end

g.test_failed_tls_is_unreachable_and_the_socket_is_closed = function()
    local double = broken_socket()

    client._set_source({
        connect = function()
            return double
        end,
        secure = function()
            return nil, 'сертификат не сошёлся'
        end,
    })

    local ws, err = websocket.connect('wss://example.org/')

    t.assert_equals(ws, nil)
    t.assert_equals(err.kind, 'unreachable')
    t.assert_equals(
        err.message,
        'TLS с example.org:443 не поднялся: сертификат не сошёлся'
    )
    t.assert_equals(double.closed, true)
end

g.test_server_that_does_not_speak_tls_is_unreachable_over_wss = function()
    -- Настоящий `tnt.tls.wrap`: сервер отвечает открытым текстом, и TLS
    -- не поднимается — это отказ `unreachable`, а не брошенное исключение.
    local listener = socket.tcp_server('127.0.0.1', 0, function(peer)
        peer:write('HTTP/1.1 400 Bad Request\r\n\r\n')
    end)
    local port = listener:name().port
    local ws, err = websocket.connect(('wss://127.0.0.1:%d/'):format(port), { timeout = 2 })

    listener:close()
    t.assert_equals(ws, nil)
    t.assert_equals(err.kind, 'unreachable')
    t.assert_str_contains(err.message, ('TLS с 127.0.0.1:%d не поднялся: '):format(port))
    t.assert_not_str_contains(err.message, ': nil')
end

--- Ответ сервера, принявшего наше предложение сжатия.
local AGREED = 'Sec-WebSocket-Extensions: permessage-deflate; server_no_context_takeover\r\n'

g.test_answer_with_our_compression_gives_the_agreement = function()
    local settings = { compress = true, protocols = { 'chat' } }

    t.assert_equals(client.verified(switching(AGREED), helper.SAMPLE_KEY, settings), { deflate = { takeover = true } })
    t.assert_equals(
        client.verified(
            switching(
                'Sec-WebSocket-Protocol: chat\r\n'
                    .. 'sec-websocket-extensions: permessage-deflate; client_no_context_takeover; '
                    .. 'server_no_context_takeover\r\n'
            ),
            helper.SAMPLE_KEY,
            settings
        ),
        { protocol = 'chat', deflate = { takeover = false } }
    )
    -- Сервер вправе сжатия не принять: разговор идёт без него.
    t.assert_equals(client.verified(switching(), helper.SAMPLE_KEY, settings), {})
end

g.test_answer_with_compression_not_by_the_rfc_is_a_refusal = function()
    local err = refused(switching('Sec-WebSocket-Extensions: permessage-deflate\r\n'), { compress = true })

    t.assert_equals(
        { err.status, err.message },
        { 101, 'сервер ответил на permessage-deflate не по RFC 7692: permessage-deflate' }
    )
end

g.test_compressing_client_offers_it_in_the_handshake = function()
    local fake = serve(switching(AGREED))
    local ws = websocket.connect(('ws://127.0.0.1:%d'):format(fake.port), { compress = true, close_timeout = 0.05 })

    t.assert_equals(
        fake.heads[1],
        ('GET / HTTP/1.1\r\nHost: 127.0.0.1:%d\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n'):format(fake.port)
            .. ('Sec-WebSocket-Key: %s\r\nSec-WebSocket-Version: 13\r\n'):format(helper.SAMPLE_KEY)
            .. 'Sec-WebSocket-Extensions: permessage-deflate; server_no_context_takeover\r\n\r\n'
    )
    t.assert_equals(ws.compressed, true)
    ws:close()
    fake.stop()
end

g.test_compressing_client_talks_in_compressed_frames = function()
    local hello = string.char(0xf2, 0x48, 0xcd, 0xc9, 0xc9, 0x07, 0x00)
    local fake = serve(function(peer)
        peer:write(switching(AGREED) .. helper.plain(frame.TEXT, hello, nil, true))
    end)
    local ws = websocket.connect(('ws://127.0.0.1:%d/'):format(fake.port), { compress = true, close_timeout = 0.05 })

    t.assert_equals(ws:receive(1), { kind = 'text', data = 'Hello' })
    t.assert_equals(ws:send('Hello'), true)

    local got =
        frame.read(helper.wire.of(fake.peers[1]), { masked = true, deflate = true, room = 1024, idle = 1, timeout = 1 })

    t.assert_equals({ got.compressed, got.payload }, { true, hello })
    ws:close()
    fake.stop()
end
