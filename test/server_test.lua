--- Тесты стороны сервера: рукопожатие и сессия на забранном соединении.

local t = require('luatest')

local clock = require('clock')
local fiber = require('fiber')
local socket = require('socket')

local helper = dofile('test/helper.lua')

local g = t.group('tnt.websocket.server')

local frame = helper.frame
local server = helper.server

--- Запрос рукопожатия, как его видит обработчик маршрута.
---@param overrides table|nil Заголовки поверх годных; `false` убирает заголовок
---@return table
local function handshake_request(overrides)
    local headers = {
        host = 'panel.example.org',
        upgrade = 'websocket',
        connection = 'keep-alive, Upgrade',
        ['sec-websocket-version'] = '13',
        ['sec-websocket-key'] = helper.SAMPLE_KEY,
    }

    for name, value in pairs(overrides or {}) do
        headers[name] = value or nil
    end

    return { method = 'GET', path = '/ws', headers = headers }
end

--- Настройки сервера с короткими сроками.
---@param overrides table|nil
---@return table
local function settings_of(overrides)
    return helper.settings.server(helper.settings_of(overrides))
end

--- Отказ проверки рукопожатия.
---@param request table
---@param overrides table|nil Настройки
---@return TntWebsocketFailure
local function refusal_of(request, overrides)
    local accepted, err = server.check(request, settings_of(overrides))

    t.assert_equals(accepted, nil)
    t.assert_equals(err.kind, 'refused')

    return err
end

g.test_only_get_starts_a_handshake = function()
    local request = handshake_request()

    request.method = 'HEAD'

    local err = refusal_of(request)

    t.assert_equals(
        { err.status, err.message },
        { 405, 'рукопожатие WebSocket идёт только способом GET' }
    )
    t.assert_equals(err.headers, { allow = 'GET' })
end

g.test_request_without_the_upgrade_is_told_to_upgrade = function()
    local expected = {
        status = 426,
        message = 'сюда ходят по WebSocket: нужны Upgrade: websocket и Connection: Upgrade',
        headers = { upgrade = 'websocket', ['sec-websocket-version'] = '13' },
    }

    for _, overrides in ipairs({
        { upgrade = false },
        { upgrade = 'h2c' },
        { connection = false },
        { connection = 'keep-alive' },
    }) do
        local err = refusal_of(handshake_request(overrides))

        t.assert_equals({ status = err.status, message = err.message, headers = err.headers }, expected)
    end
end

g.test_other_version_is_told_which_one_is_spoken = function()
    local err = refusal_of(handshake_request({ ['sec-websocket-version'] = '8' }))

    t.assert_equals(
        { err.status, err.message },
        { 426, 'версия WebSocket не та: сервер говорит на 13' }
    )
    t.assert_equals(err.headers, { upgrade = 'websocket', ['sec-websocket-version'] = '13' })
end

g.test_key_that_is_not_sixteen_bytes_is_a_bad_request = function()
    for _, key in ipairs({ false, 'короткий', 'dGhlIHNhbXBsZSBub25jZQ=' }) do
        local err = refusal_of(handshake_request({ ['sec-websocket-key'] = key }))

        t.assert_equals(
            { err.status, err.message, err.headers },
            { 400, 'ключ Sec-WebSocket-Key — не 16 байт в base64' }
        )
    end
end

g.test_page_of_another_origin_is_refused_by_default = function()
    for _, origin in ipairs({ 'https://evil.example.org', 'null', 'https://panel.example.org.evil.org' }) do
        local err = refusal_of(handshake_request({ origin = origin }))

        t.assert_equals(
            { err.status, err.message },
            { 403, 'страницам с этого источника соединение не разрешено' }
        )
    end

    t.assert_equals(refusal_of(handshake_request({ origin = 'https://panel.example.org', host = false })).status, 403)
end

g.test_own_origin_and_no_origin_pass_by_default = function()
    for _, origin in ipairs({ 'https://panel.example.org', 'HTTPS://PANEL.EXAMPLE.ORG', false }) do
        local accepted = server.check(handshake_request({ origin = origin }), settings_of())

        t.assert_equals(accepted, { key = helper.SAMPLE_KEY }, tostring(origin))
    end

    local accepted =
        server.check(handshake_request({ origin = 'http://127.0.0.1:8080', host = '127.0.0.1:8080' }), settings_of())

    t.assert_not_equals(accepted, nil)
end

g.test_listed_origins_are_the_only_ones_allowed = function()
    local settings = { origins = { 'https://Admin.example.org' } }

    t.assert_not_equals(
        server.check(handshake_request({ origin = 'https://admin.example.org' }), settings_of(settings)),
        nil
    )
    t.assert_equals(refusal_of(handshake_request({ origin = 'https://panel.example.org' }), settings).status, 403)
    t.assert_not_equals(
        server.check(handshake_request({ origin = 'https://any.example.net' }), settings_of({ origins = { '*' } })),
        nil
    )
end

g.test_protocol_is_the_first_of_the_server_that_the_client_offered = function()
    local function chosen(offered, supported)
        local accepted = server.check(
            handshake_request({ ['sec-websocket-protocol'] = offered }),
            settings_of({ protocols = supported })
        )

        return accepted.protocol
    end

    t.assert_equals(chosen('b, a', { 'a', 'b' }), 'a')
    t.assert_equals(chosen('b', { 'a', 'b' }), 'b')
    t.assert_equals(chosen('c', { 'a', 'b' }), nil)
    t.assert_equals(chosen(false, { 'a' }), nil)
    t.assert_equals(chosen('a', nil), nil)
end

g.test_request_without_headers_is_told_to_upgrade = function()
    t.assert_equals(refusal_of({ method = 'GET', path = '/ws' }).status, 426)
end

--- Сессия, которая отвечает эхом, пока соединение открыто.
---@param ws TntWebsocketConnection
local function echo(ws)
    while true do
        local message = ws:receive()

        if message == nil then
            return
        end

        ws:send(message.data, message.kind)
    end
end

g.test_accepted_handshake_answers_101_with_the_key_answered = function()
    local response = server.accept(
        handshake_request({ ['sec-websocket-protocol'] = 'chat' }),
        echo,
        settings_of({ protocols = { 'chat' } }),
        server.live()
    )

    t.assert_equals(response.status, 101)
    t.assert_equals(response.headers, {
        upgrade = 'websocket',
        connection = 'Upgrade',
        ['sec-websocket-accept'] = helper.SAMPLE_ACCEPT,
        ['sec-websocket-protocol'] = 'chat',
    })
    t.assert_equals(type(response.takeover), 'function')
end

g.test_refused_handshake_is_a_pair = function()
    local response, err = server.accept(handshake_request({ upgrade = false }), echo, settings_of(), server.live())

    t.assert_equals(response, nil)
    t.assert_equals(err.status, 426)
end

---@class TntWebsocketTaken
---@field peer table Сокет собеседника
---@field own table Сокет сервера
---@field runner table Файбер, в котором идёт takeover

--- Отдаёт соединение ответу, как это сделал бы роутер: в своём файбере.
---@param response table
---@return TntWebsocketTaken
local function taken(response)
    local own, peer = socket.socketpair('AF_UNIX', 'SOCK_STREAM', 0)
    local runner = fiber.new(response.takeover, own)

    runner:set_joinable(true)

    return { peer = peer, own = own, runner = runner }
end

--- Кадр, который прислал сервер собеседнику.
---@param session TntWebsocketTaken
---@return any
local function heard(session)
    return frame.read(helper.wire.of(session.peer), { masked = false, room = 1024 * 1024, idle = 2, timeout = 2 })
end

g.test_session_talks_over_the_taken_connection_and_ends_with_it = function()
    local live = server.live()
    local response = server.accept(handshake_request(), echo, settings_of(), live)
    local session = taken(response)

    session.peer:write(helper.masked(frame.TEXT, 'эхо?'))
    t.assert_equals(heard(session), { fin = true, compressed = false, opcode = frame.TEXT, payload = 'эхо?' })
    t.assert_equals(live.count, 1)

    session.peer:write(helper.masked(frame.CLOSE, frame.closing(1000)))
    t.assert_equals(heard(session).payload, frame.closing(1000))
    session.runner:join()
    t.assert_equals(live.count, 0)
    session.peer:close()
    session.own:close()
end

g.test_session_that_returns_closes_with_1000 = function()
    local response = server.accept(handshake_request(), function(ws)
        ws:send('и всё')
    end, settings_of({ close_timeout = 0.05 }), server.live())
    local session = taken(response)

    t.assert_equals(heard(session).payload, 'и всё')
    t.assert_equals(heard(session).payload, frame.closing(1000, ''))
    session.runner:join()
    session.peer:close()
    session.own:close()
end

g.test_fallen_session_closes_with_1011_and_leaves_a_record = function()
    local journal = helper.capture_log()

    journal.forget()

    local live = server.live()
    local response = server.accept(handshake_request(), function()
        error('сессия споткнулась: token=hunter2', 0)
    end, settings_of({ close_timeout = 0.05 }), live)
    local session = taken(response)

    t.assert_equals(heard(session).payload, frame.closing(1011, ''))
    session.runner:join()
    t.assert_equals(live.count, 0)

    local found = journal.find('ERROR [tnt.websocket] сессия WebSocket упала')

    t.assert_not_equals(found, nil)
    t.assert_equals(
        found.record.fields,
        { path = '/ws', reason = 'сессия споткнулась: token=[скрыто]' }
    )
    journal.release()
    session.peer:close()
    session.own:close()
end

g.test_session_runs_in_the_context_of_the_handshake = function()
    local context = helper.context
    local seen
    local response = context.run({ request_id = 'запрос-7' }, function()
        return server.accept(handshake_request(), function()
            seen = context.get('request_id')
        end, settings_of({ close_timeout = 0.05 }), server.live())
    end)
    local session = taken(response)

    session.runner:join()
    t.assert_equals(seen, 'запрос-7')
    session.peer:close()
    session.own:close()
end

g.test_reader_journals_a_violation_with_the_request_id = function()
    local journal = helper.capture_log()

    journal.forget()

    local response = helper.context.run({ request_id = 'запрос-9' }, function()
        return server.accept(handshake_request(), echo, settings_of({ close_timeout = 0.05 }), server.live())
    end)
    local session = taken(response)

    session.peer:write(helper.plain(frame.TEXT, 'без маски'))
    t.assert_equals(heard(session).payload, frame.closing(1002))
    session.runner:join()

    local found = journal.find('WARN [tnt.websocket] та сторона нарушила протокол WebSocket')

    t.assert_not_equals(found, nil)
    t.assert_equals(found.record.request_id, 'запрос-9')
    journal.release()
    session.peer:close()
    session.own:close()
end

g.test_full_limit_refuses_the_handshake_with_503 = function()
    -- Счёт бывает и больше предела: сессии, успевшие пройти сверку вместе.
    for _, count in ipairs({ 1, 2 }) do
        local response, err = server.accept(
            handshake_request(),
            echo,
            settings_of({ max_connections = 1 }),
            { count = count, connections = {} }
        )

        t.assert_equals(response, nil)
        t.assert_equals(
            { err.status, err.message },
            { 503, 'соединений WebSocket больше предела: попробуйте позже' }
        )
    end
end

g.test_handshakes_that_passed_together_let_only_the_limit_talk = function()
    local live = server.live()
    local settings = settings_of({ max_connections = 1, close_timeout = 0.05 })
    local first = server.accept(handshake_request(), echo, settings, live)
    local second = server.accept(handshake_request(), echo, settings, live)

    t.assert_not_equals(first, nil)
    t.assert_not_equals(second, nil)

    local talking = taken(first)

    fiber.yield()
    t.assert_equals(live.count, 1)

    local late = taken(second)

    t.assert_equals(heard(late).payload, frame.closing(1013, ''))
    late.runner:join()
    t.assert_equals(live.count, 1)

    talking.peer:write(helper.masked(frame.CLOSE, frame.closing(1000)))
    talking.runner:join()
    t.assert_equals(live.count, 0)

    for _, session in ipairs({ talking, late }) do
        session.peer:close()
        session.own:close()
    end
end

-- ─── Конечная точка ─────────────────────────────────────────────────────────

--- Сессии конечной точки — каждая на своей паре сокетов, как их отдал бы роутер.
---
--- Сессии встают в своих файберах; одной уступки хватает, чтобы каждая
--- дошла до ожидания сообщения и была учтена.
---@param endpoint TntWebsocketEndpoint
---@param count integer
---@return TntWebsocketTaken[]
local function opened(endpoint, count)
    local sessions = {}

    for _ = 1, count do
        table.insert(sessions, taken(endpoint.handler(handshake_request())))
    end

    fiber.yield()

    return sessions
end

--- Дожидается конца сессий и закрывает их сокеты.
---@param sessions TntWebsocketTaken[]
local function released(sessions)
    for _, session in ipairs(sessions) do
        session.runner:join()
        session.peer:close()
        session.own:close()
    end
end

g.test_endpoint_closes_every_session_at_once_with_1001_by_default = function()
    local endpoint = server.endpoint(echo, settings_of({ close_timeout = 0.3 }))
    local sessions = opened(endpoint, 2)

    t.assert_equals(endpoint:count(), 2)

    local started = clock.monotonic()

    t.assert_equals(endpoint:close_all(), 2)

    -- Обе стороны молчат, и каждое закрытие ждёт ответа весь срок. Разом
    -- это один срок, по одному было бы два.
    t.assert_lt(clock.monotonic() - started, 0.55)

    for _, session in ipairs(sessions) do
        t.assert_equals(
            heard(session),
            { fin = true, compressed = false, opcode = frame.CLOSE, payload = frame.closing(1001, '') }
        )
    end

    released(sessions)
    t.assert_equals(endpoint:count(), 0)
    t.assert_equals(endpoint.live.connections, {})
end

g.test_endpoint_closes_with_the_code_and_reason_given_and_hears_the_answers = function()
    local endpoint = server.endpoint(echo, settings_of({ close_timeout = 5 }))
    local sessions = opened(endpoint, 2)
    local connections = {}

    for _, connection in pairs(endpoint.live.connections) do
        table.insert(connections, connection)
    end

    local closing = fiber.new(endpoint.close_all, endpoint, 4001, 'узел уходит')

    closing:set_joinable(true)

    for _, session in ipairs(sessions) do
        t.assert_equals(heard(session).payload, frame.closing(4001, 'узел уходит'))
        session.peer:write(helper.masked(frame.CLOSE, frame.closing(4001)))
    end

    -- Ответы пришли, и закрытие не ждёт своего срока в пять секунд.
    local started = clock.monotonic()

    t.assert_equals({ closing:join() }, { true, 2 })
    t.assert_lt(clock.monotonic() - started, 1)

    for _, connection in ipairs(connections) do
        t.assert_equals({ connection.closed.code, connection.closed.reason }, { 4001, 'узел уходит' })
    end

    released(sessions)
    t.assert_equals(endpoint:count(), 0)
end

g.test_endpoint_leaves_alone_the_session_that_closes_by_itself = function()
    local gate = fiber.channel(1)
    local endpoint = server.endpoint(function(ws)
        ws:close(4000)
        gate:get()
    end, settings_of({ close_timeout = 0.05 }))
    local sessions = opened(endpoint, 1)

    -- Сессия ещё идёт, но её соединение уже закрывается: трогать его
    -- незачем, и в число закрытых оно не входит.
    t.assert_equals(endpoint:count(), 1)
    t.assert_equals(endpoint:close_all(), 0)
    t.assert_equals(heard(sessions[1] --[[@as TntWebsocketTaken]]).payload, frame.closing(4000, ''))

    gate:put(true)
    released(sessions)
    t.assert_equals(endpoint:count(), 0)
end

g.test_endpoint_without_sessions_closes_none = function()
    t.assert_equals(server.endpoint(echo, settings_of()):close_all(), 0)
end

g.test_wrong_code_or_reason_of_close_all_blames_the_caller = function()
    local endpoint = server.endpoint(echo, settings_of())

    -- Проверка идёт и без сессий: негодный код иначе всплыл бы только
    -- при остановке, когда сессии есть.
    helper.assert_blamed({
        {
            function()
                endpoint:close_all(1006)
            end,
            'код закрытия 1006 в кадре не ходит: годятся 1000–1003, 1007–1014 и 3000–4999',
        },
        {
            function()
                endpoint:close_all(1001, string.rep('я', 62))
            end,
            'причина закрытия — строка UTF-8 не длиннее 123 байт',
        },
        {
            function()
                endpoint:close_all(helper.wrong('1001'))
            end,
            'код закрытия — целое число, а не строка',
        },
    })
end

--- Предложение сжатия, как его шлют Chrome и клиент WebSocket из Node.
local OFFER = { ['sec-websocket-extensions'] = 'permessage-deflate; client_max_window_bits' }

g.test_compression_is_agreed_only_when_it_is_on_and_offered = function()
    t.assert_equals(server.check(handshake_request(OFFER), settings_of({ compress = true })), {
        key = helper.SAMPLE_KEY,
        deflate = { takeover = true },
        extensions = 'permessage-deflate; client_no_context_takeover',
    })
    t.assert_equals(server.check(handshake_request(OFFER), settings_of()), { key = helper.SAMPLE_KEY })
    t.assert_equals(server.check(handshake_request(), settings_of({ compress = true })), { key = helper.SAMPLE_KEY })
    -- Негодное предложение отказом не бывает: рукопожатие идёт без сжатия.
    t.assert_equals(
        server.check(
            handshake_request({ ['sec-websocket-extensions'] = 'permessage-deflate; server_max_window_bits=10' }),
            settings_of({ compress = true })
        ),
        { key = helper.SAMPLE_KEY }
    )
end

g.test_agreed_compression_is_named_in_the_answer = function()
    local response = server.accept(handshake_request(OFFER), echo, settings_of({ compress = true }), server.live())

    t.assert_equals(response.headers, {
        upgrade = 'websocket',
        connection = 'Upgrade',
        ['sec-websocket-accept'] = helper.SAMPLE_ACCEPT,
        ['sec-websocket-extensions'] = 'permessage-deflate; client_no_context_takeover',
    })
end

g.test_session_with_compression_unpacks_and_packs = function()
    local response = server.accept(
        handshake_request(OFFER),
        echo,
        settings_of({ compress = true, close_timeout = 0.05 }),
        server.live()
    )
    local session = taken(response)
    local text = string.rep('эхо со сжатием; ', 30)

    session.peer:write(helper.masked(frame.TEXT, helper.deflate.new({ takeover = false }):pack(text), nil, true))

    local got = frame.read(
        helper.wire.of(session.peer),
        { masked = false, deflate = true, room = 1024 * 1024, idle = 2, timeout = 2 }
    )

    t.assert_equals({ got.compressed, got.opcode }, { true, frame.TEXT })
    t.assert_equals(helper.deflate.unpack(got.payload, #text), text)

    session.peer:write(helper.masked(frame.CLOSE, frame.closing(1000)))
    session.runner:join()
    session.peer:close()
    session.own:close()
end
