--- Тесты сжатия: договор permessage-deflate и байты сжатых сообщений.
---
--- Байты сверяются с примерами RFC 7692 (§7.2.3), а не с тем, что пишет сам
--- пакет: иначе сжатие и разжатие сошлись бы друг с другом и в ошибке.

local t = require('luatest')

local helper = dofile('test/helper.lua')

local g = t.group('tnt.websocket.deflate')

local deflate = helper.deflate

--- Байты строкой из чисел.
---@param ... integer
---@return string
local function bytes(...)
    return string.char(...)
end

--- «Hello» одним сжатым блоком (§7.2.3.1).
local HELLO = bytes(0xf2, 0x48, 0xcd, 0xc9, 0xc9, 0x07, 0x00)

--- Второе «Hello» тем же словарём: ссылка назад на первое (§7.2.3.2).
local HELLO_AGAIN = bytes(0xf2, 0x00, 0x11, 0x00, 0x00)

--- Ответ сервера по умолчанию: сообщения клиента — каждое с пустым словарём.
local ANSWER = 'permessage-deflate; client_no_context_takeover'

g.after_each(function()
    helper.restore()
end)

g.test_hello_is_packed_as_in_the_rfc_and_the_second_one_refers_back = function()
    local squeezer = deflate.new({ takeover = true })

    t.assert_equals(squeezer:pack('Hello'), HELLO)
    t.assert_equals(squeezer:pack('Hello'), HELLO_AGAIN)
end

g.test_without_takeover_every_message_is_packed_afresh = function()
    local squeezer = deflate.new({ takeover = false })

    t.assert_equals(squeezer:pack('Hello'), HELLO)
    t.assert_equals(squeezer:pack('Hello'), HELLO)
end

g.test_samples_of_the_rfc_unpack_to_hello = function()
    t.assert_equals(deflate.unpack(HELLO, 5), 'Hello')
    -- Несжатый блок DEFLATE (§7.2.3.3) и два блока в одном сообщении (§7.2.3.5).
    t.assert_equals(deflate.unpack(bytes(0x00, 0x05, 0x00, 0xfa, 0xff, 0x48, 0x65, 0x6c, 0x6c, 0x6f, 0x00), 5), 'Hello')
    t.assert_equals(
        deflate.unpack(bytes(0xf2, 0x48, 0x05, 0x00, 0x00, 0x00, 0xff, 0xff, 0xca, 0xc9, 0xc9, 0x07, 0x00), 5),
        'Hello'
    )
    -- Пустое сообщение: пустой несжатый блок и вовсе пустые данные.
    t.assert_equals(deflate.unpack(bytes(0x00), 5), '')
    t.assert_equals(deflate.unpack('', 5), '')
end

g.test_packed_message_unpacks_back = function()
    local text = string.rep('{"node":"storage-001","state":"alive"}\n', 200)
    local packed = deflate.new({ takeover = true }):pack(text)

    t.assert_lt(#packed, #text / 20)
    t.assert_equals(deflate.unpack(packed, #text), text)
end

g.test_unpacked_up_to_the_limit_is_taken_and_one_byte_more_is_too_big = function()
    local packed = deflate.new({ takeover = false }):pack(string.rep('x', 2000))
    local data, trouble = deflate.unpack(packed, 1999)

    t.assert_equals(deflate.unpack(packed, 2000), string.rep('x', 2000))
    t.assert_equals(data, nil)
    t.assert_equals(
        trouble,
        { code = 1009, reason = 'разжатое сообщение длиннее 1999 байт' }
    )
end

g.test_broken_packed_message_is_invalid_data = function()
    local data, trouble = deflate.unpack(bytes(0xff, 0xff), 100)

    t.assert_equals(data, nil)
    t.assert_equals(trouble, {
        code = 1007,
        reason = 'сжатое сообщение не разжимается: сжатые данные испорчены: invalid block type',
    })
end

g.test_message_ended_with_the_final_block_is_not_read = function()
    -- Сжатие с концом потока DEFLATE (§7.2.3.4): хвост ложится за конец.
    local data, trouble = deflate.unpack(bytes(0xf3, 0x48, 0xcd, 0xc9, 0xc9, 0x07, 0x00, 0x00), 100)

    t.assert_equals(data, nil)
    t.assert_equals(trouble.code, 1007)
end

g.test_client_offers_compression_without_the_server_dictionary = function()
    t.assert_equals(deflate.NAME, 'permessage-deflate')
    t.assert_equals(deflate.OFFER, 'permessage-deflate; server_no_context_takeover')
end

--- Договор сервера по заголовку предложений: договор и ответ.
---@param value string|nil
---@return table
local function accepted(value)
    local agreement, answer = deflate.accept(value)

    return { agreement, answer }
end

g.test_server_accepts_what_browsers_offer = function()
    t.assert_equals(accepted('permessage-deflate'), { { takeover = true }, ANSWER })
    -- Так предлагают Chrome и клиент WebSocket из Node.
    t.assert_equals(accepted('permessage-deflate; client_max_window_bits'), { { takeover = true }, ANSWER })
    t.assert_equals(
        accepted('permessage-deflate; client_no_context_takeover; client_max_window_bits=10'),
        { { takeover = true }, ANSWER }
    )
end

g.test_server_keeps_no_dictionary_when_asked_and_says_so = function()
    t.assert_equals(accepted('permessage-deflate; server_no_context_takeover'), {
        { takeover = false },
        'permessage-deflate; client_no_context_takeover; server_no_context_takeover',
    })
end

g.test_server_repeats_its_window_when_it_is_asked_for_the_widest = function()
    t.assert_equals(accepted('permessage-deflate; server_max_window_bits=15'), {
        { takeover = true },
        'permessage-deflate; client_no_context_takeover; server_max_window_bits=15',
    })
    t.assert_equals(accepted(' permessage-deflate ; server_max_window_bits = "15" ; client_max_window_bits="8" '), {
        { takeover = true },
        'permessage-deflate; client_no_context_takeover; server_max_window_bits=15',
    })
end

g.test_every_window_of_the_client_from_8_to_15_is_fine = function()
    for bits = 8, 15 do
        local offer = ('permessage-deflate; client_max_window_bits=%d'):format(bits)

        t.assert_equals(accepted(offer), { { takeover = true }, ANSWER }, offer)
    end
end

g.test_offers_the_server_cannot_keep_are_declined = function()
    for _, offer in ipairs({
        'permessage-deflate; server_max_window_bits=14',
        'permessage-deflate; server_max_window_bits=8',
        'permessage-deflate; server_max_window_bits',
        'permessage-deflate; server_max_window_bits=015',
        'permessage-deflate; client_max_window_bits=7',
        'permessage-deflate; client_max_window_bits=16',
        'permessage-deflate; client_max_window_bits=08',
        'permessage-deflate; client_max_window_bits=',
        'permessage-deflate; server_no_context_takeover=1',
        'permessage-deflate; client_no_context_takeover=true',
        'permessage-deflate; mux',
        'permessage-deflate; client_no_context_takeover; client_no_context_takeover',
        'permessage-deflate; server_max_window_bits=15; server_max_window_bits=15',
        'x-webkit-deflate-frame',
        '',
    }) do
        t.assert_equals(accepted(offer), {}, offer)
    end

    t.assert_equals(accepted(nil), {})
end

g.test_first_fit_offer_wins_and_empty_elements_are_skipped = function()
    t.assert_equals(
        accepted('permessage-deflate; server_max_window_bits=10, permessage-deflate; server_no_context_takeover'),
        { { takeover = false }, 'permessage-deflate; client_no_context_takeover; server_no_context_takeover' }
    )
    t.assert_equals(accepted('x-webkit-deflate-frame, , permessage-deflate,'), { { takeover = true }, ANSWER })
end

g.test_client_agrees_on_an_answer_by_the_rfc = function()
    t.assert_equals(deflate.agreed('permessage-deflate; server_no_context_takeover'), { takeover = true })
    t.assert_equals(
        deflate.agreed('permessage-deflate; client_no_context_takeover; server_no_context_takeover'),
        { takeover = false }
    )
    t.assert_equals(deflate.agreed('permessage-deflate;server_no_context_takeover,'), { takeover = true })

    -- Окно сервера — любое годное: разжатие окном в 15 бит читает и меньшее.
    for bits = 8, 15 do
        local answer = ('permessage-deflate; server_no_context_takeover; server_max_window_bits=%d'):format(bits)

        t.assert_equals(deflate.agreed(answer), { takeover = true }, answer)
    end
end

g.test_client_refuses_an_answer_it_did_not_ask_for = function()
    for _, answer in ipairs({
        -- Сервер держит словарь, а разжатие у нас с пустым.
        'permessage-deflate',
        'permessage-deflate; client_no_context_takeover',
        -- Окна клиента мы не предлагали, окно сервера — вне 8…15.
        'permessage-deflate; server_no_context_takeover; client_max_window_bits=15',
        'permessage-deflate; server_no_context_takeover; server_max_window_bits=16',
        'permessage-deflate; server_no_context_takeover; server_max_window_bits',
        'permessage-deflate; server_no_context_takeover; mux',
        'permessage-deflate; server_no_context_takeover; server_no_context_takeover',
        'permessage-deflate; server_no_context_takeover, permessage-deflate; server_no_context_takeover',
        'x-webkit-deflate-frame; server_no_context_takeover',
        '',
    }) do
        t.assert_equals(deflate.agreed(answer), nil, answer)
    end
end
