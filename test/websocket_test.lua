--- Тесты фасада: сервер на маршруте роутера и клиент пакета разговаривают
--- через настоящий `http.server` на петле.
---
--- Это и есть проверка стыка двух договоров: рукопожатие идёт роутером как
--- обычный запрос, отказ — его обработчиком отказов, а соединение после 101
--- забирает `tnt.router.takeover`.

local t = require('luatest')

local http_client = require('http.client')
local http_server = require('http.server')

local helper = dofile('test/helper.lua')

local g = t.group('tnt.websocket.facade')

local websocket = helper.websocket

--- Эхо, пока соединение открыто; `bye` — закрыть самим кодом 4000.
---@param ws TntWebsocketConnection
local function echo(ws)
    while true do
        local message = ws:receive()

        if message == nil then
            return
        end

        if message.data == 'bye' then
            ws:close(4000, 'как просили')

            return
        end

        ws:send(message.data, message.kind)
    end
end

g.before_each(function()
    g.router = helper.load_router()
    g.httpd = http_server.new('127.0.0.1', 0, { log_requests = false, log_errors = false, idle_timeout = 5 })
end)

g.after_each(function()
    if g.httpd.is_run then
        g.httpd:stop()
    end

    helper.unload_router()
end)

--- Поднимает сервер с маршрутами и отдаёт адрес.
---@return string
local function started()
    g.router.attach(g.httpd)
    g.httpd:start()

    return ('127.0.0.1:%d'):format(g.httpd.tcp_server:name().port)
end

g.test_client_and_server_talk_through_the_router = function()
    g.router.get('/ws/:room', websocket.handler(echo, { protocols = { 'echo.v1' } }))

    local ws, err = websocket.connect(('ws://%s/ws/lobby'):format(started()), { protocols = { 'echo.v1' } })

    t.assert_equals(err, nil)
    t.assert_equals(ws.protocol, 'echo.v1')
    t.assert_equals(ws:send('привет'), true)
    t.assert_equals(ws:receive(2), { kind = 'text', data = 'привет' })
    t.assert_equals(ws:send(string.rep('\0\255', 40000), websocket.BINARY), true)
    t.assert_equals(ws:receive(2), { kind = 'binary', data = string.rep('\0\255', 40000) })

    t.assert_equals(ws:close(), true)
    t.assert_equals(ws.closed.code, websocket.NORMAL)
end

g.test_server_side_close_reaches_the_client_with_its_code = function()
    g.router.get('/ws', websocket.handler(echo))

    local ws = websocket.connect(('ws://%s/ws'):format(started()))

    ws:send('bye')

    local message, err = ws:receive(2)

    t.assert_equals(message, nil)
    t.assert_equals({ err.kind, err.code, err.reason }, { websocket.CLOSED, 4000, 'как просили' })
    t.assert_equals(ws:is_open(), false)
end

g.test_session_gets_the_handshake_request_with_its_params = function()
    local seen

    g.router.get(
        '/ws/:room',
        websocket.handler(function(ws, request)
            seen = { room = request.params.room, token = request.query.token, protocol = ws.protocol }
        end)
    )

    local ws = websocket.connect(('ws://%s/ws/kitchen?token=7'):format(started()))
    local _, err = ws:receive(2)

    t.assert_equals(err.code, websocket.NORMAL)
    t.assert_equals(seen, { room = 'kitchen', token = '7' })
end

g.test_plain_request_to_the_socket_is_told_to_upgrade_by_the_router = function()
    g.router.get('/ws', websocket.handler(echo))

    local answer = http_client.new():get(('http://%s/ws'):format(started()), { timeout = 2 })

    t.assert_equals(answer.status, 426)
    t.assert_equals(answer.headers.upgrade, 'websocket')
    t.assert_equals(answer.headers['sec-websocket-version'], '13')
    t.assert_equals(
        require('json').decode(answer.body --[[@as string]]).error.message,
        'сюда ходят по WebSocket: нужны Upgrade: websocket и Connection: Upgrade'
    )
end

g.test_refused_handshake_is_a_refusal_for_the_client = function()
    g.router.get('/ws', websocket.handler(echo, { max_connections = 1 }))

    local address = started()
    local first = websocket.connect(('ws://%s/ws'):format(address))
    local second, err = websocket.connect(('ws://%s/ws'):format(address))

    t.assert_equals(second, nil)
    t.assert_equals({ err.kind, err.status }, { websocket.REFUSED, 503 })
    first:close()
end

g.test_missing_route_is_a_refusal_with_its_status = function()
    local ws, err = websocket.connect(('ws://%s/nowhere'):format(started()))

    t.assert_equals(ws, nil)
    t.assert_equals({ err.kind, err.status }, { websocket.REFUSED, 404 })
end

g.test_route_can_refuse_before_the_handshake = function()
    local talk = websocket.handler(echo)

    g.router.get('/ws', function(request)
        if request.query.token ~= 'secret' then
            return nil, { status = 401, message = 'нужен вход' }
        end

        return talk(request)
    end)

    local address = started()
    local _, err = websocket.connect(('ws://%s/ws'):format(address))

    t.assert_equals(err.status, 401)

    local ws = websocket.connect(('ws://%s/ws?token=secret'):format(address))

    t.assert_equals(ws:is_open(), true)
    ws:close()
end

g.test_endpoint_closes_every_session_before_the_server_stops = function()
    local chat = websocket.endpoint(echo)

    g.router.get('/ws', chat.handler)

    local address = started()
    local clients = {}

    for _ = 1, 2 do
        table.insert(clients, (websocket.connect(('ws://%s/ws'):format(address))))
    end

    t.assert_equals(chat:count(), 2)
    t.assert_equals(chat:close_all(websocket.GOING_AWAY, 'узел уходит'), 2)
    g.httpd:stop()

    for _, ws in ipairs(clients) do
        local message, err = ws:receive(2)

        t.assert_equals(message, nil)
        t.assert_equals({ err.kind, err.code, err.reason }, { websocket.CLOSED, 1001, 'узел уходит' })
    end

    t.helpers.retrying({ timeout = 2 }, function()
        t.assert_equals(chat:count(), 0)
    end)
end

g.test_session_must_be_callable = function()
    helper.assert_blamed({
        {
            function()
                websocket.handler(helper.wrong('echo'))
            end,
            'сессия WebSocket — функция или вызываемая таблица, а не строка',
        },
        {
            function()
                websocket.endpoint(helper.wrong('echo'))
            end,
            'сессия WebSocket — функция или вызываемая таблица, а не строка',
        },
    })
end

g.test_facade_names_the_codes_kinds_and_refusals = function()
    t.assert_equals({
        websocket.NORMAL,
        websocket.GOING_AWAY,
        websocket.PROTOCOL_ERROR,
        websocket.UNSUPPORTED_DATA,
        websocket.NO_STATUS,
        websocket.ABNORMAL,
        websocket.INVALID_DATA,
        websocket.POLICY_VIOLATION,
        websocket.MESSAGE_TOO_BIG,
        websocket.MANDATORY_EXTENSION,
        websocket.INTERNAL_ERROR,
        websocket.SERVICE_RESTART,
        websocket.TRY_AGAIN_LATER,
    }, { 1000, 1001, 1002, 1003, 1005, 1006, 1007, 1008, 1009, 1010, 1011, 1012, 1013 })
    t.assert_equals({ websocket.TEXT, websocket.BINARY }, { 'text', 'binary' })
    t.assert_equals(
        { websocket.CLOSED, websocket.TIMEOUT, websocket.INVALID, websocket.REFUSED, websocket.UNREACHABLE },
        { 'closed', 'timeout', 'invalid', 'refused', 'unreachable' }
    )
end

g.test_client_and_server_talk_compressed_when_both_want_it = function()
    local seen

    g.router.get(
        '/ws',
        websocket.handler(function(ws)
            seen = ws.compressed
            echo(ws)
        end, { compress = true, max_message = 256 * 1024 })
    )

    local ws = websocket.connect(('ws://%s/ws'):format(started()), { compress = true, max_message = 256 * 1024 })
    local snapshot = require('json').encode({ nodes = { { name = 'storage-001', state = 'alive' } } })
    local big = string.rep(snapshot, 3000)

    t.assert_equals(ws.compressed, true)

    -- Три сообщения подряд: словарь сжатия держит только сервер, и второе
    -- с третьим он сжимает ссылками на первое.
    for _, data in ipairs({ snapshot, snapshot, big }) do
        t.assert_equals(ws:send(data), true)
        t.assert_equals(ws:receive(2), { kind = 'text', data = data })
    end

    t.assert_equals(seen, true)
    t.assert_equals(ws:close(), true)
end

g.test_compression_wanted_by_one_side_only_is_not_agreed = function()
    g.router.get('/plain', websocket.handler(echo))
    g.router.get('/packed', websocket.handler(echo, { compress = true }))

    local address = started()

    for _, case in ipairs({ { 'plain', { compress = true } }, { 'packed', {} } }) do
        local ws = websocket.connect(('ws://%s/%s'):format(address, case[1]), case[2])

        t.assert_equals(ws.compressed, false, case[1])
        t.assert_equals(ws:send('привет'), true)
        t.assert_equals(ws:receive(2), { kind = 'text', data = 'привет' })
        ws:close()
    end
end
