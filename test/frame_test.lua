--- Тесты кадра: запись, разбор, маска, длины и кадр закрытия.
---
--- Байты сверяются с примерами RFC 6455 (§5.7), а не с тем, что пишет
--- сам пакет: иначе запись и разбор сошлись бы друг с другом и в ошибке.

local t = require('luatest')

local helper = dofile('test/helper.lua')

local g = t.group('tnt.websocket.frame')

local frame = helper.frame

--- Правила сервера: входящие кадры с маской.
---@param room integer|nil
---@return TntWebsocketRules
local function server_rules(room)
    return { masked = true, room = room or 1024 * 1024, idle = 7, timeout = 3 }
end

--- Правила клиента: входящие кадры без маски.
---@return TntWebsocketRules
local function client_rules()
    return { masked = false, room = 1024 * 1024, idle = 7, timeout = 3 }
end

--- Сокет из строки: отдаёт байты, как сокет, и помнит, что просили.
---
--- Кончившаяся строка ведёт себя по `tail`: `nil` — молчание (срок вышел),
--- `''` — конец потока, и тогда просимое отдаётся тем, что осталось.
---@param text string
---@param tail string|nil
---@return table wire
---@return table asked `{ size, timeout }` по порядку
local function wire_of(text, tail)
    local at = 1
    local asked = {}

    return {
        read = function(_, size, timeout)
            table.insert(asked, { size, timeout })

            local rest = text:sub(at)

            if #rest >= size then
                at = at + size

                return rest:sub(1, size)
            end

            if tail == nil then
                return nil
            end

            at = #text + 1

            return rest
        end,
    },
        asked
end

--- Байты строкой из чисел.
---@param ... integer
---@return string
local function bytes(...)
    return string.char(...)
end

g.test_unmasked_hello_is_written_as_in_the_rfc = function()
    t.assert_equals(frame.encode(frame.TEXT, 'Hello'), bytes(0x81, 0x05, 0x48, 0x65, 0x6c, 0x6c, 0x6f))
end

g.test_masked_hello_is_written_as_in_the_rfc = function()
    t.assert_equals(
        frame.encode(frame.TEXT, 'Hello', helper.KEY),
        bytes(0x81, 0x85, 0x37, 0xfa, 0x21, 0x3d, 0x7f, 0x9f, 0x4d, 0x51, 0x58)
    )
end

g.test_masked_pong_is_written_as_in_the_rfc = function()
    t.assert_equals(
        frame.encode(frame.PONG, 'Hello', helper.KEY),
        bytes(0x8a, 0x85, 0x37, 0xfa, 0x21, 0x3d, 0x7f, 0x9f, 0x4d, 0x51, 0x58)
    )
end

g.test_opcodes_are_the_numbers_of_the_rfc = function()
    t.assert_equals(
        { frame.CONTINUATION, frame.TEXT, frame.BINARY, frame.CLOSE, frame.PING, frame.PONG },
        { 0, 1, 2, 8, 9, 10 }
    )
    t.assert_equals({ frame.MAX_CONTROL, frame.MAX_REASON }, { 125, 123 })
end

g.test_lengths_take_seven_sixteen_or_sixty_four_bits = function()
    local cases = {
        { 0, bytes(0x82, 0x00) },
        { 125, bytes(0x82, 0x7D) },
        { 126, bytes(0x82, 0x7E, 0x00, 0x7E) },
        { 258, bytes(0x82, 0x7E, 0x01, 0x02) },
        { 65535, bytes(0x82, 0x7E, 0xFF, 0xFF) },
        { 65536, bytes(0x82, 0x7F, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00) },
    }

    for _, case in ipairs(cases) do
        local payload = string.rep('x', case[1])
        local written = frame.encode(frame.BINARY, payload)

        t.assert_equals(written:sub(1, #case[2]), case[2], case[1])
        t.assert_equals(written:sub(#case[2] + 1), payload, case[1])
    end
end

g.test_masked_long_frame_carries_the_mark_in_the_length_byte = function()
    local written = frame.encode(frame.BINARY, string.rep('x', 300), helper.KEY)

    t.assert_equals(written:sub(1, 8), bytes(0x82, 0xFE, 0x01, 0x2C) .. helper.KEY)
end

g.test_every_length_reads_back_whole = function()
    for _, size in ipairs({ 0, 1, 125, 126, 258, 40000, 65535, 65536, 70000 }) do
        local payload = string.rep('ab', size):sub(1, size)
        local wire = wire_of(frame.encode(frame.BINARY, payload, helper.KEY))
        local got = frame.read(wire, server_rules())

        t.assert_equals(got, { fin = true, compressed = false, opcode = frame.BINARY, payload = payload }, size)
    end
end

g.test_masked_hello_reads_as_text = function()
    local wire, asked = wire_of(bytes(0x81, 0x85, 0x37, 0xfa, 0x21, 0x3d, 0x7f, 0x9f, 0x4d, 0x51, 0x58))

    t.assert_equals(
        frame.read(wire, server_rules()),
        { fin = true, compressed = false, opcode = frame.TEXT, payload = 'Hello' }
    )
    -- Начала кадра ждут `idle`, каждой следующей части — `timeout`.
    t.assert_equals(asked, { { 2, 7 }, { 4, 3 }, { 5, 3 } })
end

g.test_unmasked_ping_reads_on_the_client = function()
    local wire, asked = wire_of(bytes(0x89, 0x05, 0x48, 0x65, 0x6c, 0x6c, 0x6f))

    t.assert_equals(
        frame.read(wire, client_rules()),
        { fin = true, compressed = false, opcode = frame.PING, payload = 'Hello' }
    )
    t.assert_equals(asked, { { 2, 7 }, { 5, 3 } })
end

g.test_fragments_of_the_rfc_read_one_by_one = function()
    local wire = wire_of(bytes(0x01, 0x03, 0x48, 0x65, 0x6c, 0x80, 0x02, 0x6c, 0x6f))

    t.assert_equals(
        frame.read(wire, client_rules()),
        { fin = false, compressed = false, opcode = frame.TEXT, payload = 'Hel' }
    )
    t.assert_equals(
        frame.read(wire, client_rules()),
        { fin = true, compressed = false, opcode = frame.CONTINUATION, payload = 'lo' }
    )
end

g.test_sixteen_bit_length_with_the_high_bit_is_fine = function()
    local payload = string.rep('z', 40000)
    local got = frame.read(wire_of(frame.encode(frame.TEXT, payload)), client_rules())

    t.assert_equals(got.payload, payload)
end

g.test_empty_payload_is_read_without_waiting = function()
    local wire, asked = wire_of(bytes(0x8A, 0x00))

    t.assert_equals(
        frame.read(wire, client_rules()),
        { fin = true, compressed = false, opcode = frame.PONG, payload = '' }
    )
    t.assert_equals(asked, { { 2, 7 }, { 0, 3 } })
end

--- Разбор, который обязан отказать: код и причина беды.
---@param text string
---@param rules TntWebsocketRules
---@param tail string|nil
---@return table
local function trouble_of(text, rules, tail)
    local got, trouble = frame.read(wire_of(text, tail), rules)

    t.assert_equals(got, nil)

    return trouble
end

g.test_reserved_bits_break_the_protocol = function()
    for _, first in ipairs({ 0xC1, 0xA1, 0x91 }) do
        t.assert_equals(trouble_of(bytes(first, 0x80) .. helper.KEY, server_rules()), {
            code = 1002,
            reason = 'зарезервированные биты кадра без расширения',
        })
    end
end

g.test_unknown_opcodes_break_the_protocol = function()
    for _, opcode in ipairs({ 3, 7, 11, 15 }) do
        t.assert_equals(
            trouble_of(bytes(0x80 + opcode, 0x80) .. helper.KEY, server_rules()),
            { code = 1002, reason = ('незнакомый код кадра %d'):format(opcode) }
        )
    end
end

g.test_client_frame_without_a_mask_breaks_the_protocol = function()
    t.assert_equals(
        trouble_of(bytes(0x81, 0x00), server_rules()),
        { code = 1002, reason = 'кадр клиента без маски' }
    )
end

g.test_server_frame_with_a_mask_breaks_the_protocol = function()
    t.assert_equals(
        trouble_of(bytes(0x81, 0x80) .. helper.KEY, client_rules()),
        { code = 1002, reason = 'кадр сервера с маской' }
    )
end

g.test_control_frame_in_parts_or_too_long_breaks_the_protocol = function()
    local expected =
        { code = 1002, reason = 'управляющий кадр частями или длиннее 125 байт' }

    t.assert_equals(trouble_of(bytes(0x09, 0x80) .. helper.KEY, server_rules()), expected)
    t.assert_equals(trouble_of(bytes(0x89, 0xFE, 0x00, 0x7E), server_rules()), expected)
    t.assert_equals(trouble_of(bytes(0x88, 0xFE, 0x00, 0x7E), server_rules()), expected)
end

g.test_control_frame_of_125_bytes_is_fine = function()
    local payload = string.rep('p', 125)

    t.assert_equals(frame.read(wire_of(frame.encode(frame.PING, payload)), client_rules()).payload, payload)
end

g.test_huge_length_with_the_high_bit_breaks_the_protocol = function()
    t.assert_equals(
        trouble_of(bytes(0x82, 0xFF, 0x80, 0, 0, 0, 0, 0, 0, 1), server_rules()),
        { code = 1002, reason = 'длина кадра с поднятым старшим битом' }
    )
end

g.test_huge_length_without_the_high_bit_is_only_too_big = function()
    t.assert_equals(
        trouble_of(bytes(0x82, 0xFF, 0x7F, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF), server_rules()),
        { code = 1009, reason = 'сообщение длиннее 1048576 байт' }
    )
end

g.test_payload_up_to_the_room_is_read_and_one_more_byte_is_too_big = function()
    local fits = frame.encode(frame.BINARY, string.rep('r', 10), helper.KEY)

    t.assert_equals(frame.read(wire_of(fits), server_rules(10)).payload, string.rep('r', 10))
    -- Данные слишком длинного кадра не читаются вовсе: отказ раньше них.
    t.assert_equals(
        trouble_of(frame.encode(frame.BINARY, string.rep('r', 11), helper.KEY):sub(1, 2), server_rules(10)),
        { code = 1009, reason = 'сообщение длиннее 10 байт' }
    )
end

g.test_silence_before_a_frame_is_the_silent_sign = function()
    local _, trouble = frame.read(wire_of(''), server_rules())

    t.assert_is(trouble, frame.SILENT)
    t.assert_equals(frame.SILENT.code, 1006)
end

g.test_end_of_stream_before_a_frame_is_an_abnormal_end = function()
    for _, text in ipairs({ '', bytes(0x81) }) do
        t.assert_equals(trouble_of(text, server_rules(), ''), {
            code = 1006,
            reason = 'та сторона закрыла соединение без кадра закрытия',
        })
    end
end

g.test_frame_cut_short_anywhere_is_an_abnormal_end = function()
    local whole = frame.encode(frame.BINARY, string.rep('c', 300), helper.KEY)
    local expected = {
        code = 1006,
        reason = 'кадр не пришёл целиком: соединение оборвано или молчит',
    }

    -- Оборвано на длине, на ключе и на данных; и молчанием, и концом потока.
    for _, cut in ipairs({ 3, 6, 20 }) do
        t.assert_equals(trouble_of(whole:sub(1, cut), server_rules()), expected, cut)
        t.assert_equals(trouble_of(whole:sub(1, cut), server_rules(), ''), expected, cut)
    end

    t.assert_equals(trouble_of(bytes(0x82, 0xFF, 0, 0), server_rules()), expected)
end

g.test_mask_is_undone_by_the_same_key = function()
    local text = 'маска по кругу: 0123456789'
    local masked = frame.mask(text, helper.KEY)

    t.assert_not_equals(masked, text)
    t.assert_equals(frame.mask(masked, helper.KEY), text)
    t.assert_equals(frame.mask('Hello', helper.KEY), bytes(0x7f, 0x9f, 0x4d, 0x51, 0x58))
    t.assert_equals(frame.mask('', helper.KEY), '')
end

g.test_numbers_go_big_endian_both_ways = function()
    t.assert_equals(frame.big_endian(258, 2), bytes(1, 2))
    t.assert_equals(frame.big_endian(65536, 8), bytes(0, 0, 0, 0, 0, 1, 0, 0))
    t.assert_equals(frame.big_endian(16909060, 4), bytes(1, 2, 3, 4))
    t.assert_equals(frame.number_of(bytes(1, 2)), 258)
    t.assert_equals(frame.number_of(bytes(0, 0, 0, 0, 0, 1, 0, 0)), 65536)
    t.assert_equals(frame.number_of(bytes(1, 2, 3, 4)), 16909060)
    t.assert_equals(frame.number_of(''), 0)
end

g.test_closing_payload_is_the_code_and_the_reason = function()
    t.assert_equals(frame.closing(1000, 'пока'), bytes(0x03, 0xE8) .. 'пока')
    t.assert_equals(frame.closing(4001), bytes(0x0F, 0xA1))
    t.assert_equals(frame.closing(nil), '')
end

g.test_closing_payload_reads_back = function()
    t.assert_equals(frame.closed_by(''), { code = 1005, reason = '' })
    t.assert_equals(frame.closed_by(bytes(0x03, 0xE8)), { code = 1000, reason = '' })
    t.assert_equals(frame.closed_by(bytes(0x0F, 0xA1) .. 'ухожу'), { code = 4001, reason = 'ухожу' })
end

g.test_broken_closing_payload_is_a_trouble = function()
    local function refused(payload)
        local closing, trouble = frame.closed_by(payload)

        t.assert_equals(closing, nil)

        return trouble
    end

    t.assert_equals(refused(bytes(0x03)), { code = 1002, reason = 'кадр закрытия в один байт' })
    t.assert_equals(
        refused(bytes(0x03, 0xEC)),
        { code = 1002, reason = 'код закрытия 1004 в кадре не ходит' }
    )
    t.assert_equals(
        refused(bytes(0x03, 0xE7)),
        { code = 1002, reason = 'код закрытия 999 в кадре не ходит' }
    )
    t.assert_equals(
        refused(bytes(0x03, 0xE8, 0xFF)),
        { code = 1007, reason = 'причина закрытия не в UTF-8' }
    )
end

g.test_trouble_is_a_code_and_a_reason = function()
    t.assert_equals(frame.trouble(1002, 'нарушение'), { code = 1002, reason = 'нарушение' })
end

g.test_control_frames_do_not_count_against_the_room_of_a_message = function()
    -- Сообщение собрано до предела: места под данные нет, а ping и закрытие
    -- приходят как всегда.
    local ping = frame.read(wire_of(frame.encode(frame.PING, 'тук', helper.KEY)), server_rules(0))
    local close = frame.read(wire_of(frame.encode(frame.CLOSE, frame.closing(1000), helper.KEY)), server_rules(0))

    t.assert_equals(ping.payload, 'тук')
    t.assert_equals(close.payload, frame.closing(1000))
    t.assert_equals(
        trouble_of(frame.encode(frame.CONTINUATION, 'x', helper.KEY), server_rules(0)),
        { code = 1009, reason = 'сообщение длиннее 0 байт' }
    )
end

--- Правила сервера, договорившегося о сжатии.
---@return TntWebsocketRules
local function compressing_rules()
    local rules = server_rules()

    rules.deflate = true

    return rules
end

g.test_compressed_hello_is_written_as_in_the_rfc = function()
    -- RFC 7692, §7.2.3.1: «Hello» одним сжатым блоком, RSV1 поднят.
    local packed = bytes(0xf2, 0x48, 0xcd, 0xc9, 0xc9, 0x07, 0x00)

    t.assert_equals(frame.encode(frame.TEXT, packed, nil, true), bytes(0xc1, 0x07) .. packed)
    t.assert_equals(frame.encode(frame.BINARY, packed, helper.KEY, true):sub(1, 2), bytes(0xc2, 0x87))
    t.assert_equals(frame.encode(frame.TEXT, 'Hello', nil, false), frame.encode(frame.TEXT, 'Hello'))
end

g.test_compression_bit_of_a_data_message_reads_once_agreed = function()
    for _, opcode in ipairs({ frame.TEXT, frame.BINARY }) do
        local got = frame.read(wire_of(frame.encode(opcode, 'сжато', helper.KEY, true)), compressing_rules())

        t.assert_equals(got, { fin = true, compressed = true, opcode = opcode, payload = 'сжато' })
    end

    local plain = frame.read(wire_of(frame.encode(frame.TEXT, 'как есть', helper.KEY)), compressing_rules())

    t.assert_equals(plain.compressed, false)
end

g.test_compression_bit_of_a_continuation_or_a_control_frame_breaks_the_protocol = function()
    for _, opcode in ipairs({ frame.CONTINUATION, frame.PING, frame.PONG, frame.CLOSE }) do
        t.assert_equals(trouble_of(frame.encode(opcode, '', helper.KEY, true), compressing_rules()), {
            code = 1002,
            reason = 'бит сжатия RSV1 у продолжения сообщения или управляющего кадра',
        }, opcode)
    end
end

g.test_other_reserved_bits_break_the_protocol_even_with_compression = function()
    for _, first in ipairs({ 0xA1, 0x91, 0xE1, 0xD2 }) do
        t.assert_equals(trouble_of(bytes(first, 0x80) .. helper.KEY, compressing_rules()), {
            code = 1002,
            reason = 'зарезервированные биты кадра без расширения',
        })
    end
end

g.test_unknown_opcode_is_named_before_its_reserved_bits = function()
    t.assert_equals(
        trouble_of(bytes(0xC3, 0x80) .. helper.KEY, compressing_rules()),
        { code = 1002, reason = 'незнакомый код кадра 3' }
    )
end
