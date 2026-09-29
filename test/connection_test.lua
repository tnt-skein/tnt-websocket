--- Тесты соединения на настоящей паре сокетов.

local t = require('luatest')

local clock = require('clock')
local fiber = require('fiber')

local helper = dofile('test/helper.lua')

local g = t.group('tnt.websocket.connection')

local frame = helper.frame
local connection_of = helper.connection

--- Пары, заведённые проверкой: их гасят после неё.
local pairs_made = {}

--- Пара сокетов с соединением пакета на одном конце.
---@param overrides table|nil
---@param client boolean|nil
---@param deflate TntWebsocketDeflate|nil Договор о сжатии
---@return TntWebsocketPair
local function pair(overrides, client, deflate)
    local made = helper.pair(overrides, client, deflate)

    table.insert(pairs_made, made)

    return made
end

g.after_each(function()
    for _, made in ipairs(pairs_made) do
        connection_of.halt(made.connection)
        pcall(made.peer.close, made.peer)
        pcall(made.own.close, made.own)
    end

    pairs_made = {}
    helper.restore()
end)

--- Кадр, который прислало соединение, либо ничего за короткий срок.
---@param made TntWebsocketPair
---@param masked boolean|nil
---@return TntWebsocketFrame|nil
---@return table|nil
local function quick(made, masked)
    return frame.read(made.wire, { masked = masked == true, room = 1024 * 1024, idle = 0.1, timeout = 0.1 })
end

g.test_text_and_binary_messages_arrive_in_order = function()
    local made = pair()

    made.peer:write(helper.masked(frame.TEXT, 'привет') .. helper.masked(frame.BINARY, '\0\1\2'))

    t.assert_equals(made.connection:receive(1), { kind = 'text', data = 'привет' })
    t.assert_equals(made.connection:receive(1), { kind = 'binary', data = '\0\1\2' })
    t.assert_equals(made.connection.protocol, 'chat')
    t.assert_equals(made.connection.request, { path = '/ws' })
    t.assert_equals(made.connection:is_open(), true)
end

g.test_fragments_are_gathered_and_a_ping_between_them_is_answered = function()
    local made = pair()

    made.peer:write(
        helper.masked(frame.TEXT, 'при', false)
            .. helper.masked(frame.PING, 'тук')
            .. helper.masked(frame.CONTINUATION, 'в', false)
            .. helper.masked(frame.CONTINUATION, 'ет')
    )

    t.assert_equals(made.connection:receive(1), { kind = 'text', data = 'привет' })
    t.assert_equals(helper.heard(made), { fin = true, compressed = false, opcode = frame.PONG, payload = 'тук' })
end

g.test_ping_amid_a_message_at_its_limit_is_still_answered = function()
    local made = pair()

    made.peer:write(
        helper.masked(frame.BINARY, string.rep('x', 1024), false)
            .. helper.masked(frame.PING, 'тук')
            .. helper.masked(frame.CONTINUATION, '')
    )

    t.assert_equals(helper.heard(made), { fin = true, compressed = false, opcode = frame.PONG, payload = 'тук' })
    t.assert_equals(made.connection:receive(1).data, string.rep('x', 1024))
end

g.test_empty_fragments_change_nothing_in_the_message = function()
    local made = pair()

    made.peer:write(
        helper.masked(frame.TEXT, 'при', false)
            .. helper.masked(frame.CONTINUATION, '', false)
            .. helper.masked(frame.CONTINUATION, '', false)
            .. helper.masked(frame.CONTINUATION, 'вет')
    )

    t.assert_equals(made.connection:receive(1), { kind = 'text', data = 'привет' })
end

g.test_pong_from_the_peer_is_taken_silently = function()
    local made = pair()

    made.peer:write(helper.masked(frame.PONG, 'x') .. helper.masked(frame.TEXT, 'дальше'))

    t.assert_equals(made.connection:receive(1), { kind = 'text', data = 'дальше' })
    t.assert_equals(select(2, quick(made)), frame.SILENT)
end

g.test_sent_messages_go_out_as_single_unmasked_frames = function()
    local made = pair()

    t.assert_equals(made.connection:send('привет'), true)
    t.assert_equals(made.connection:send('\255\0', 'binary'), true)
    t.assert_equals(made.connection:send('явно', 'text'), true)

    t.assert_equals(
        helper.heard(made),
        { fin = true, compressed = false, opcode = frame.TEXT, payload = 'привет' }
    )
    t.assert_equals(helper.heard(made), { fin = true, compressed = false, opcode = frame.BINARY, payload = '\255\0' })
    t.assert_equals(helper.heard(made), { fin = true, compressed = false, opcode = frame.TEXT, payload = 'явно' })
end

g.test_text_that_is_not_utf8_is_not_sent_and_the_connection_lives = function()
    local made = pair()
    local sent, err = made.connection:send('\255\254')

    t.assert_equals(sent, nil)
    t.assert_equals(err.kind, 'invalid')
    t.assert_equals(err.message, 'текст сообщения не в UTF-8: такое шлют видом binary')
    t.assert_equals(select(2, quick(made)), frame.SILENT)
    t.assert_equals(made.connection:is_open(), true)
end

g.test_wrong_arguments_blame_the_caller = function()
    local made = pair()
    local ws = made.connection

    helper.assert_blamed({
        {
            function()
                ws:send(helper.wrong(42))
            end,
            'сообщение — строка, а не число',
        },
        {
            function()
                ws:send('a', 'json')
            end,
            'вид сообщения — одно из «text», «binary», а не «json»',
        },
        {
            function()
                ws:receive(-1)
            end,
            'срок ожидания сообщения — число не меньше 0, а не -1',
        },
        {
            function()
                ws:close(1005)
            end,
            'код закрытия 1005 в кадре не ходит: годятся 1000–1003, 1007–1014 и 3000–4999',
        },
        {
            function()
                ws:close(1000.5)
            end,
            'код закрытия — целое число, а не 1000.5',
        },
        {
            function()
                ws:close(1000, helper.wrong(7))
            end,
            'причина закрытия — строка, а не число',
        },
        {
            function()
                ws:close(1000, string.rep('я', 62))
            end,
            'причина закрытия — строка UTF-8 не длиннее 123 байт',
        },
        {
            function()
                ws:close(1000, '\255')
            end,
            'причина закрытия — строка UTF-8 не длиннее 123 байт',
        },
    })

    -- Ни одна негодная попытка соединения не тронула.
    t.assert_equals(ws:is_open(), true)
end

g.test_reason_of_exactly_123_bytes_is_fine = function()
    local made = pair({ close_timeout = 0.05 })

    t.assert_equals(made.connection:close(4000, string.rep('r', 123)), true)
    t.assert_equals(helper.heard(made).payload, frame.closing(4000, string.rep('r', 123)))
end

g.test_nothing_to_receive_is_a_timeout_and_not_a_close = function()
    local made = pair()
    local message, err = made.connection:receive(0.05)

    t.assert_equals(message, nil)
    t.assert_equals(err.kind, 'timeout')
    t.assert_equals(err.message, 'сообщения нет за 0.05 с')
    t.assert_equals(made.connection:is_open(), true)
end

g.test_close_of_the_peer_is_echoed_and_ends_receiving = function()
    local made = pair()

    made.peer:write(
        helper.masked(frame.TEXT, 'последнее') .. helper.masked(frame.CLOSE, frame.closing(4001, 'пока'))
    )

    t.assert_equals(
        helper.heard(made),
        { fin = true, compressed = false, opcode = frame.CLOSE, payload = frame.closing(4001) }
    )
    t.assert_equals(made.connection:receive(1), { kind = 'text', data = 'последнее' })

    local message, err = made.connection:receive(1)

    t.assert_equals(message, nil)
    t.assert_equals({ err.kind, err.code, err.reason }, { 'closed', 4001, 'пока' })
    t.assert_equals(err.message, 'та сторона закрыла соединение')
    t.assert_equals(made.connection:is_open(), false)
    t.assert_equals(made.connection.state, 'closed')
    -- Закрытое отвечает тем же итогом и дальше, не дожидаясь срока.
    t.assert_is(select(2, made.connection:receive()), err)
    t.assert_is(select(2, made.connection:send('ещё')), err)
end

g.test_close_without_a_code_is_answered_without_one = function()
    local made = pair()

    made.peer:write(helper.masked(frame.CLOSE, ''))

    t.assert_equals(helper.heard(made), { fin = true, compressed = false, opcode = frame.CLOSE, payload = '' })
    helper.settled(made.connection)
    t.assert_equals(made.connection.closed.code, 1005)
end

g.test_waiting_receiver_is_woken_by_the_close = function()
    local made = pair()
    ---@type any
    local got

    local waiting = fiber.new(function()
        got = { made.connection:receive(5) }
    end)

    waiting:set_joinable(true)
    fiber.yield()
    made.peer:write(helper.masked(frame.CLOSE, frame.closing(1000)))

    local started = clock.monotonic()

    waiting:join()
    t.assert_lt(clock.monotonic() - started, 1)
    t.assert_equals(got[1], nil)
    t.assert_equals(got[2].code, 1000)
end

g.test_own_close_waits_for_the_answer_of_the_peer = function()
    local made = pair({ close_timeout = 5 })
    local closed

    local closing = fiber.new(function()
        closed = made.connection:close(4000, 'ухожу')
    end)

    closing:set_joinable(true)

    t.assert_equals(
        helper.heard(made),
        { fin = true, compressed = false, opcode = frame.CLOSE, payload = frame.closing(4000, 'ухожу') }
    )
    t.assert_equals(made.connection.state, 'closing')

    -- Пока ответа нет, слать нельзя: соединение закрывается.
    local sent, err = made.connection:send('ещё')

    t.assert_equals(sent, nil)
    t.assert_equals(
        { err.kind, err.code, err.reason, err.message },
        { 'closed', 4000, 'ухожу', 'соединение закрывается' }
    )

    -- Сообщение той стороны после нашего закрытия уже никто не ждёт.
    made.peer:write(helper.masked(frame.TEXT, 'поздно') .. helper.masked(frame.CLOSE, frame.closing(1000)))

    local started = clock.monotonic()

    closing:join()
    t.assert_lt(clock.monotonic() - started, 1)
    t.assert_equals(closed, true)
    t.assert_equals({ made.connection.closed.code, made.connection.closed.reason }, { 4000, 'ухожу' })
    t.assert_equals(made.connection.closed.message, 'соединение закрыто')
    t.assert_equals(select(2, made.connection:receive(0)).code, 4000)
    -- Второе закрытие ничего не шлёт.
    t.assert_equals(made.connection:close(), true)
    t.assert_equals(select(2, quick(made)), frame.SILENT)
end

g.test_own_close_without_an_answer_ends_after_the_close_timeout = function()
    local made = pair({ close_timeout = 0.2 })

    -- Отметка цикла событий отстаёт на работу без уступки перед закрытием;
    -- под нагрузкой полного прогона такая работа случается и сама. Срок,
    -- отсчитанный от отметки, кончился бы раньше на всё её время.
    helper.work_without_yielding(0.1)

    local started = clock.monotonic()

    t.assert_equals(made.connection:close(), true)

    local elapsed = clock.monotonic() - started

    t.assert_ge(elapsed, 0.2)
    t.assert_lt(elapsed, 1)
    t.assert_equals(helper.heard(made).payload, frame.closing(1000, ''))
    t.assert_equals({ made.connection.closed.code, made.connection.closed.reason }, { 1000, '' })
    t.assert_equals(
        made.connection.closed.message,
        'соединение закрыто: та сторона не ответила на закрытие'
    )
end

g.test_own_close_ends_when_the_clock_shows_exactly_its_deadline = function()
    -- Срок — миг: часы, показавшие ровно его, ответа больше не ждут,
    -- и остаток ожидания не спрашивается вовсе. Первое чтение отмечает
    -- срок, второе сверяет его; третьего быть не должно. Отметка цикла —
    -- за сотую долю секунды до срока: начнись ожидание всё же, оно
    -- кончилось бы сразу, и проверка упала бы на счёте, а не повисла.
    local shown = { 1000, 1000.25 }
    local reads, remainders = 0, 0

    helper.connection._set_source({
        monotonic = function()
            reads = reads + 1

            return shown[reads] or 1001
        end,
        scheduler_now = function()
            remainders = remainders + 1

            return 1000.24
        end,
    })

    local made = pair({ close_timeout = 0.25 })

    t.assert_equals(made.connection:close(), true)
    t.assert_equals({ reads = reads, remainders = remainders }, { reads = 2, remainders = 0 })
    t.assert_equals(
        made.connection.closed.message,
        'соединение закрыто: та сторона не ответила на закрытие'
    )
end

g.test_own_close_woken_before_its_deadline_waits_the_rest = function()
    local made = pair({ close_timeout = 0.2 })

    local closing = fiber.new(function()
        made.connection:close()
    end)

    closing:set_joinable(true)

    local started = clock.monotonic()

    -- Закрытие ушло и ждёт ответа. Побудка не от той стороны срока
    -- не кончает: разбуженное ждёт остаток.
    fiber.yield()
    t.assert_equals({ made.connection.state, closing:status() }, { 'closing', 'suspended' })
    fiber.wakeup(closing)
    closing:join()

    t.assert_ge(clock.monotonic() - started, 0.2)
    t.assert_equals(
        made.connection.closed.message,
        'соединение закрыто: та сторона не ответила на закрытие'
    )
end

g.test_close_meeting_the_close_of_the_peer_does_not_wait = function()
    -- Замок записи занят длинным сообщением, которое собеседник не читает:
    -- наше закрытие ждёт очереди, а закрытие той стороны тем временем
    -- приходит и кончает соединение. Ждать ответа после этого нечего.
    local send_timeout = 5
    local made = pair({ close_timeout = 5, send_timeout = send_timeout })
    local big = string.rep('b', 4 * 1024 * 1024)

    fiber.create(function()
        made.connection:send(big, 'binary')
    end)

    local closing = fiber.new(function()
        made.connection:close()
    end)

    closing:set_joinable(true)
    fiber.sleep(0.05)
    made.peer:write(helper.masked(frame.CLOSE, frame.closing(1001)))
    helper.settled(made.connection)

    -- Сообщение дописывается, пока собеседник его читает, и под нагрузкой
    -- идёт дольше срока помощника: кадр ждётся тем же сроком, что отпущен
    -- записи.
    t.assert_equals(helper.heard(made, false, send_timeout).payload, big)

    -- Замок свободен, наш кадр закрытия уходит. Время меряется от этого
    -- мига: перегон четырёх мегабайт к закрытию не относится, а ожидание
    -- ответа заняло бы весь `close_timeout`.
    local started = clock.monotonic()

    closing:join()
    t.assert_lt(clock.monotonic() - started, 2)
    t.assert_equals(made.connection.closed.code, 1000)
end

g.test_writers_of_two_fibers_do_not_mix_their_frames = function()
    local send_timeout = 5
    local made = pair({ send_timeout = send_timeout })
    local big = string.rep('m', 3 * 1024 * 1024)
    local results = {}

    local first = fiber.new(function()
        results.big = made.connection:send(big, 'binary')
    end)
    local second = fiber.new(function()
        results.small = made.connection:send('маленькое')
    end)

    first:set_joinable(true)
    second:set_joinable(true)

    -- Длинный кадр ждётся сроком записи, как и в проверке выше.
    t.assert_equals(helper.heard(made, false, send_timeout).payload, big)
    t.assert_equals(helper.heard(made).payload, 'маленькое')
    first:join()
    second:join()
    t.assert_equals(results, { big = true, small = true })
end

g.test_busy_writer_makes_the_next_one_time_out = function()
    local made = pair({ send_timeout = 0.05 })

    -- Замок занят, будто пишет другой файбер.
    made.connection.lock:put(true)

    local sent, err = made.connection:send('подожду')

    made.connection.lock:get()
    t.assert_equals(sent, nil)
    t.assert_equals(err.kind, 'timeout')
    t.assert_equals(err.message, 'запись ждала очереди дольше 0.05 с')
    t.assert_equals(made.connection:is_open(), true)
end

g.test_failed_write_closes_the_connection_as_abnormal = function()
    local made = pair()

    made.peer:close()

    local sent, err = made.connection:send(string.rep('x', 1000))

    t.assert_equals(sent, nil)
    t.assert_equals({ err.kind, err.code, err.reason }, { 'closed', 1006, '' })
    t.assert_str_contains(err.message, 'соединение оборвалось на записи: ')
    t.assert_equals(made.connection:is_open(), false)
end

--- Нарушение той стороны: что она получила и чем кончилось соединение.
---@param bytes string Что прислал собеседник
---@param overrides table|nil
---@param deflate TntWebsocketDeflate|nil Договор о сжатии
---@return any answer Кадр закрытия, который ушёл нарушителю
---@return any closed Итог соединения
---@return table journal Записи журнала
local function violated(bytes, overrides, deflate)
    local journal = helper.capture_log()

    journal.forget()

    local made = pair(overrides, nil, deflate)

    made.peer:write(bytes)

    local answer = helper.heard(made)

    helper.settled(made.connection)

    local records = journal.records()

    journal.release()

    return answer, made.connection.closed, records
end

g.test_protocol_violation_is_answered_with_1002_and_journaled = function()
    local answer, closed, records = violated(helper.plain(frame.TEXT, 'без маски'))

    t.assert_equals(answer, { fin = true, compressed = false, opcode = frame.CLOSE, payload = frame.closing(1002) })
    t.assert_equals({ closed.kind, closed.code, closed.reason }, { 'closed', 1002, '' })
    t.assert_equals(
        closed.message,
        'соединение разорвано: кадр клиента без маски'
    )
    t.assert_equals(#records, 1)
    t.assert_equals(records[1].level, 'warn')
    t.assert_equals(records[1].module, 'tnt.websocket')
    t.assert_equals(records[1].record.message, 'та сторона нарушила протокол WebSocket')
    t.assert_equals(records[1].record.fields, { code = 1002, reason = 'кадр клиента без маски' })
end

g.test_continuation_without_a_start_breaks_the_protocol = function()
    local answer, closed = violated(helper.masked(frame.CONTINUATION, 'хвост'))

    t.assert_equals(answer.payload, frame.closing(1002))
    t.assert_equals(
        closed.message,
        'соединение разорвано: продолжение без начала сообщения'
    )
end

g.test_new_message_amid_the_previous_breaks_the_protocol = function()
    local answer, closed =
        violated(helper.masked(frame.TEXT, 'нача', false) .. helper.masked(frame.TEXT, 'другое'))

    t.assert_equals(answer.payload, frame.closing(1002))
    t.assert_equals(
        closed.message,
        'соединение разорвано: новое сообщение посреди прежнего'
    )
end

g.test_text_that_is_not_utf8_is_answered_with_1007 = function()
    local answer, closed = violated(helper.masked(frame.TEXT, 'ok\255'))

    t.assert_equals(answer.payload, frame.closing(1007))
    t.assert_equals(
        { closed.code, closed.message },
        { 1007, 'соединение разорвано: текст сообщения не в UTF-8' }
    )
end

g.test_broken_close_frame_is_answered_with_1002 = function()
    local answer, closed = violated(helper.masked(frame.CLOSE, '\3'))

    t.assert_equals(answer.payload, frame.closing(1002))
    t.assert_equals(
        closed.message,
        'соединение разорвано: кадр закрытия в один байт'
    )
end

g.test_message_bigger_than_the_limit_is_answered_with_1009 = function()
    local answer, closed = violated(helper.masked(frame.BINARY, string.rep('x', 1025)))

    t.assert_equals(answer.payload, frame.closing(1009))
    t.assert_equals(
        closed.message,
        'соединение разорвано: сообщение длиннее 1024 байт'
    )
end

g.test_fragments_count_together_against_the_limit = function()
    local answer, closed = violated(
        helper.masked(frame.BINARY, string.rep('x', 600), false)
            .. helper.masked(frame.CONTINUATION, string.rep('y', 425))
    )

    t.assert_equals(answer.payload, frame.closing(1009))
    t.assert_equals(
        closed.message,
        'соединение разорвано: сообщение длиннее 424 байт'
    )
end

g.test_every_fragment_adds_to_what_the_message_already_took = function()
    local answer, closed = violated(
        helper.masked(frame.BINARY, string.rep('x', 400), false)
            .. helper.masked(frame.CONTINUATION, string.rep('y', 400), false)
            .. helper.masked(frame.CONTINUATION, string.rep('z', 300))
    )

    t.assert_equals(answer.payload, frame.closing(1009))
    t.assert_equals(
        closed.message,
        'соединение разорвано: сообщение длиннее 224 байт'
    )
end

g.test_three_fragments_of_exactly_the_limit_arrive = function()
    local made = pair()

    made.peer:write(
        helper.masked(frame.BINARY, 'ab', false)
            .. helper.masked(frame.CONTINUATION, 'cde', false)
            .. helper.masked(frame.CONTINUATION, string.rep('f', 1019))
    )

    t.assert_equals(made.connection:receive(1).data, 'abcde' .. string.rep('f', 1019))
end

g.test_message_of_exactly_the_limit_in_fragments_arrives = function()
    local made = pair()

    made.peer:write(
        helper.masked(frame.BINARY, string.rep('x', 600), false)
            .. helper.masked(frame.CONTINUATION, string.rep('y', 424))
    )

    t.assert_equals(made.connection:receive(1).data, string.rep('x', 600) .. string.rep('y', 424))
end

g.test_peer_gone_without_a_close_is_an_abnormal_end_without_a_record = function()
    local journal = helper.capture_log()

    journal.forget()

    local made = pair()

    made.peer:close()
    helper.settled(made.connection)

    t.assert_equals({ made.connection.closed.code, made.connection.closed.reason }, { 1006, '' })
    t.assert_equals(
        made.connection.closed.message,
        'соединение разорвано: та сторона закрыла соединение без кадра закрытия'
    )
    t.assert_equals(journal.records(), {})
    journal.release()
end

g.test_silence_brings_a_ping_and_the_pong_keeps_the_connection = function()
    local made = pair({ ping_interval = 0.1 })

    t.assert_equals(helper.heard(made), { fin = true, compressed = false, opcode = frame.PING, payload = '' })
    made.peer:write(helper.masked(frame.PONG, ''))
    -- Ответ пришёл — следующее молчание снова даёт ping, а не обрыв.
    t.assert_equals(helper.heard(made), { fin = true, compressed = false, opcode = frame.PING, payload = '' })
    t.assert_equals(made.connection:is_open(), true)
end

g.test_silence_after_a_ping_is_an_abnormal_end = function()
    local made = pair({ ping_interval = 0.1 })

    t.assert_equals(helper.heard(made).opcode, frame.PING)
    helper.settled(made.connection)
    t.assert_equals(made.connection.closed.code, 1006)
    t.assert_equals(
        made.connection.closed.message,
        'соединение разорвано: та сторона не ответила на ping за 0.1 с'
    )
end

g.test_closing_connection_does_not_ping_in_the_silence = function()
    local made = pair({ ping_interval = 0.05, close_timeout = 0.3 })

    t.assert_equals(made.connection:close(), true)
    t.assert_equals(helper.heard(made).opcode, frame.CLOSE)
    t.assert_equals(select(2, quick(made)), frame.SILENT)
end

g.test_full_inbox_holds_the_reader_and_nothing_is_lost = function()
    local made = pair({ backlog = 1 })

    for index = 1, 5 do
        made.peer:write(helper.masked(frame.TEXT, tostring(index)))
    end

    for index = 1, 5 do
        t.assert_equals(made.connection:receive(1).data, tostring(index))
    end
end

g.test_client_masks_its_frames_with_fresh_keys = function()
    helper.connection._set_source({
        random = function(size)
            t.assert_equals(size, 4)

            return helper.KEY
        end,
    })

    local made = pair(nil, true)

    t.assert_equals(made.connection:send('Hello'), true)
    t.assert_equals(
        made.peer:read(11, 1),
        string.char(0x81, 0x85, 0x37, 0xfa, 0x21, 0x3d, 0x7f, 0x9f, 0x4d, 0x51, 0x58)
    )
end

g.test_client_reads_plain_frames_and_refuses_masked_ones = function()
    local made = pair(nil, true)

    made.peer:write(helper.plain(frame.TEXT, 'сервер'))
    t.assert_equals(made.connection:receive(1).data, 'сервер')

    made.peer:write(helper.masked(frame.TEXT, 'с маской'))
    t.assert_equals(helper.heard(made, true).payload, frame.closing(1002))
    helper.settled(made.connection)
    t.assert_equals(
        made.connection.closed.message,
        'соединение разорвано: кадр сервера с маской'
    )
end

g.test_client_closes_its_socket_when_done = function()
    local made = pair({ close_timeout = 0.05 }, true)

    made.connection:close()

    -- Сокет клиента закрыт: собеседник читает кадр закрытия и конец потока.
    t.assert_equals(helper.heard(made, true).opcode, frame.CLOSE)
    t.assert_equals(made.peer:read(1, 1), '')
end

g.test_server_leaves_its_socket_to_the_http_server = function()
    local made = pair({ close_timeout = 0.05 })

    made.connection:close()

    t.assert_equals(helper.heard(made).opcode, frame.CLOSE)
    t.assert_equals(made.peer:read(1, 0.1), nil)
    t.assert_equals(made.own:write('жив'), 6)
end

g.test_halt_stops_an_open_connection = function()
    local made = pair()

    connection_of.halt(made.connection)
    connection_of.halt(made.connection)

    t.assert_equals(made.connection.state, 'closed')
    t.assert_equals(made.connection.closed.code, 1006)
    t.assert_equals(made.connection.closed.message, 'соединение закрыто')
    t.assert_equals(made.connection.reader:status(), 'dead')
end

g.test_reader_stopped_by_a_broken_socket_ends_the_connection = function()
    local made = pair()

    -- Сокет закрыт у читателя под ногами: чтение бросает, а не отвечает.
    made.own:close()
    helper.settled(made.connection)

    t.assert_equals(made.connection.closed.code, 1006)
    t.assert_str_contains(made.connection.closed.message, 'чтение оборвалось: ')
end

g.test_wire_write_reports_the_error_of_the_socket = function()
    local made = pair()
    local own = helper.wire.of(made.own)

    made.peer:close()

    local written, err = own:write(string.rep('x', 1000), 1)

    t.assert_equals(written, false)
    t.assert_equals(type(err), 'string')
    t.assert_not_equals(err, 'nil')

    made.own:close()

    written, err = own:write('x', 1)
    t.assert_equals(written, false)
    t.assert_str_contains(err, 'closed socket')
    own:close()
end

--- Договор о сжатии, в котором наше сжатие держит словарь.
local KEEPING = { takeover = true }

--- «Hello» одним сжатым блоком и второе «Hello» тем же словарём (RFC 7692, §7.2.3).
local HELLO = string.char(0xf2, 0x48, 0xcd, 0xc9, 0xc9, 0x07, 0x00)
local HELLO_AGAIN = string.char(0xf2, 0x00, 0x11, 0x00, 0x00)

--- Сжатое сообщение собеседника: каждое — с пустым словарём, как договорено.
---@param text string
---@return string
local function packed(text)
    return helper.deflate.new({ takeover = false }):pack(text)
end

g.test_compressed_messages_arrive_unpacked_and_plain_ones_as_they_are = function()
    local made = pair(nil, nil, KEEPING)

    made.peer:write(
        helper.masked(frame.TEXT, HELLO, nil, true)
            .. helper.masked(frame.BINARY, packed('\0\1\2'), nil, true)
            .. helper.masked(frame.TEXT, 'как есть')
    )

    t.assert_equals(made.connection.compressed, true)
    t.assert_equals(made.connection:receive(1), { kind = 'text', data = 'Hello' })
    t.assert_equals(made.connection:receive(1), { kind = 'binary', data = '\0\1\2' })
    t.assert_equals(made.connection:receive(1), { kind = 'text', data = 'как есть' })
end

g.test_compressed_message_in_fragments_is_unpacked_whole = function()
    local made = pair(nil, nil, KEEPING)
    local bytes = packed('привет, сжатый мир')

    made.peer:write(
        helper.masked(frame.TEXT, bytes:sub(1, 4), false, true)
            .. helper.masked(frame.PING, 'тук')
            .. helper.masked(frame.CONTINUATION, bytes:sub(5))
    )

    t.assert_equals(made.connection:receive(1), { kind = 'text', data = 'привет, сжатый мир' })
end

g.test_sent_messages_are_compressed_with_the_dictionary_kept = function()
    local made = pair(nil, nil, KEEPING)

    t.assert_equals(made.connection:send('Hello'), true)
    t.assert_equals(made.connection:send('Hello', 'binary'), true)
    -- Пустое уходит несжатым: сжимать в нём нечего.
    t.assert_equals(made.connection:send(''), true)

    t.assert_equals(helper.heard(made), { fin = true, compressed = true, opcode = frame.TEXT, payload = HELLO })
    t.assert_equals(helper.heard(made), { fin = true, compressed = true, opcode = frame.BINARY, payload = HELLO_AGAIN })
    t.assert_equals(helper.heard(made), { fin = true, compressed = false, opcode = frame.TEXT, payload = '' })
end

g.test_sent_messages_are_compressed_afresh_when_the_peer_asked = function()
    local made = pair(nil, nil, { takeover = false })

    made.connection:send('Hello')
    made.connection:send('Hello')

    t.assert_equals(helper.heard(made).payload, HELLO)
    t.assert_equals(helper.heard(made).payload, HELLO)
end

g.test_client_masks_its_compressed_frames = function()
    local made = pair(nil, true, KEEPING)

    made.connection:send('Hello')

    t.assert_equals(helper.heard(made, true), { fin = true, compressed = true, opcode = frame.TEXT, payload = HELLO })
end

g.test_control_frames_go_out_uncompressed = function()
    local made = pair(nil, nil, KEEPING)

    made.peer:write(helper.masked(frame.PING, 'тук'))

    t.assert_equals(helper.heard(made), { fin = true, compressed = false, opcode = frame.PONG, payload = 'тук' })
end

g.test_unpacked_message_of_exactly_the_limit_arrives = function()
    local made = pair(nil, nil, KEEPING)

    made.peer:write(helper.masked(frame.BINARY, packed(string.rep('x', 1024)), nil, true))

    t.assert_equals(made.connection:receive(1).data, string.rep('x', 1024))
end

g.test_unpacked_message_bigger_than_the_limit_is_answered_with_1009 = function()
    -- Сто килобайт нулей сжимаются в сотню байт — «бомба» для предела
    -- в 1024 байта: по сжатому предел её не видит.
    local bomb = packed(string.rep('\0', 100 * 1024))

    t.assert_lt(#bomb, 1024)

    local answer, closed = violated(helper.masked(frame.BINARY, bomb, nil, true), nil, KEEPING)

    t.assert_equals(answer.payload, frame.closing(1009))
    t.assert_equals(
        closed.message,
        'соединение разорвано: разжатое сообщение длиннее 1024 байт'
    )
end

g.test_broken_compressed_message_is_answered_with_1007 = function()
    local answer, closed = violated(helper.masked(frame.TEXT, '\255\255', nil, true), nil, KEEPING)

    t.assert_equals(answer.payload, frame.closing(1007))
    t.assert_equals(
        closed.message,
        'соединение разорвано: сжатое сообщение не разжимается: сжатые данные испорчены: invalid block type'
    )
end

g.test_unpacked_text_that_is_not_utf8_is_answered_with_1007 = function()
    local answer, closed = violated(helper.masked(frame.TEXT, packed('\255\254'), nil, true), nil, KEEPING)

    t.assert_equals(answer.payload, frame.closing(1007))
    t.assert_equals(
        closed.message,
        'соединение разорвано: текст сообщения не в UTF-8'
    )
end

g.test_compression_bit_without_an_agreement_breaks_the_protocol = function()
    local answer, closed = violated(helper.masked(frame.TEXT, HELLO, nil, true))

    t.assert_equals(answer.payload, frame.closing(1002))
    t.assert_equals(
        closed.message,
        'соединение разорвано: зарезервированные биты кадра без расширения'
    )
end

g.test_cancelled_compression_frees_the_lock_and_closes_the_connection = function()
    local made = pair(nil, nil, KEEPING)
    ---@type any
    local outcome = nil

    -- Сообщение длиннее куска работы сжатия: между кусками сжатие уступает,
    -- и отмена застаёт его посреди сообщения, под замком записи.
    local sender = fiber.create(function()
        outcome = { made.connection:send(string.rep('сжатие ', 40000)) }
    end)

    sender:set_joinable(true)
    sender:cancel()
    sender:join()

    t.assert_equals(outcome[1], nil)
    t.assert_equals({ outcome[2].code, outcome[2].reason }, { 1006, '' })
    t.assert_equals(outcome[2].message, 'сжатие сообщения оборвалось: fiber is cancelled')
    t.assert_equals(made.connection:is_open(), false)
    t.assert_equals(made.connection.lock:is_empty(), true)
    -- Недосжатое не ушло вовсе: у собеседника ни байта.
    t.assert_equals(select(2, quick(made)), frame.SILENT)
end
