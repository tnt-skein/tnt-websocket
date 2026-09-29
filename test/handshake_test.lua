--- Тесты общего рукопожатия: ответ на ключ, списки, образцы.

local t = require('luatest')

local helper = dofile('test/helper.lua')

local g = t.group('tnt.websocket.handshake')

local handshake = helper.handshake

g.test_answer_to_the_sample_key_is_the_one_of_the_rfc = function()
    t.assert_equals(handshake.accept_of(helper.SAMPLE_KEY), helper.SAMPLE_ACCEPT)
    t.assert_equals(handshake.GUID, '258EAFA5-E914-47DA-95CA-C5AB0DC85B11')
    t.assert_equals(handshake.VERSION, '13')
end

g.test_list_header_is_split_by_commas_and_trimmed = function()
    t.assert_equals(handshake.listed(' keep-alive ,Upgrade,, chat '), { 'keep-alive', 'Upgrade', 'chat' })
    t.assert_equals(handshake.listed(nil), {})
    t.assert_equals(handshake.listed(''), {})
end

g.test_word_in_a_list_header_is_found_whatever_its_case = function()
    t.assert_equals(handshake.names('keep-alive, Upgrade', 'upgrade'), true)
    t.assert_equals(handshake.names('WebSocket', 'websocket'), true)
    t.assert_equals(handshake.names('upgrades', 'upgrade'), false)
    t.assert_equals(handshake.names(nil, 'upgrade'), false)
end

g.test_key_is_exactly_sixteen_bytes_of_base64 = function()
    t.assert_not_equals(helper.SAMPLE_KEY:match(handshake.KEY), nil)
    t.assert_not_equals(('A'):rep(21) .. 'w==', nil)

    for _, key in ipairs({
        ('A'):rep(21) .. 'w==',
        ('+'):rep(21) .. 'Q==',
        ('/'):rep(21) .. 'g==',
    }) do
        t.assert_not_equals(key:match(handshake.KEY), nil, key)
    end

    for _, key in ipairs({
        'dGhlIHNhbXBsZSBub25jZQ=',
        'dGhlIHNhbXBsZSBub25jZQ===',
        'dGhlIHNhbXBsZSBub25jZR==',
        'dGhlIHNhbXBsZSBub25jZ Q==',
        'dGhlIHNhbXBsZSBub25jZQ==x',
        '',
    }) do
        t.assert_equals(key:match(handshake.KEY), nil, key)
    end
end

g.test_protocol_name_is_an_http_token = function()
    for _, name in ipairs({ 'chat', 'v1.json', "a!#$%&'*+-.^_`|~9" }) do
        t.assert_not_equals(name:match(handshake.TOKEN), nil, name)
    end

    for _, name in ipairs({ 'чат', 'a b', 'a,b', 'a/b', '' }) do
        t.assert_equals(name:match(handshake.TOKEN), nil, name)
    end
end
