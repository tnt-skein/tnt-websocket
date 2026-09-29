--- Тесты кодов закрытия и отказа.

local t = require('luatest')

local helper = dofile('test/helper.lua')

local g = t.group('tnt.websocket.codes')

local codes = helper.codes
local failure = helper.failure

g.test_codes_are_the_numbers_of_the_rfc = function()
    t.assert_equals({
        codes.NORMAL,
        codes.GOING_AWAY,
        codes.PROTOCOL_ERROR,
        codes.UNSUPPORTED_DATA,
        codes.NO_STATUS,
        codes.ABNORMAL,
        codes.INVALID_DATA,
        codes.POLICY_VIOLATION,
        codes.MESSAGE_TOO_BIG,
        codes.MANDATORY_EXTENSION,
        codes.INTERNAL_ERROR,
        codes.SERVICE_RESTART,
        codes.TRY_AGAIN_LATER,
    }, { 1000, 1001, 1002, 1003, 1005, 1006, 1007, 1008, 1009, 1010, 1011, 1012, 1013 })
end

g.test_only_the_codes_of_the_registry_and_of_applications_travel = function()
    -- Список RFC 6455 и реестра IANA записан здесь заново, а не взят
    -- из пакета: иначе проверка сверяла бы таблицу саму с собой.
    local function expected(code)
        return (code >= 1000 and code <= 1003) or (code >= 1007 and code <= 1014) or (code >= 3000 and code <= 4999)
    end

    for code = 0, 5100 do
        t.assert_equals(codes.sendable(code), expected(code), code)
    end
end

g.test_failure_speaks_its_text_everywhere = function()
    local err = failure.new(failure.CLOSED, 'соединение закрыто', { code = 1000, reason = 'пока' })

    t.assert_equals(tostring(err), 'соединение закрыто')
    t.assert_equals('итог: ' .. err, 'итог: соединение закрыто')
    t.assert_equals(err .. '!', 'соединение закрыто!')
    t.assert_equals(require('json').encode({ err = err }), '{"err":"соединение закрыто"}')
    t.assert_equals({ err.kind, err.code, err.reason }, { 'closed', 1000, 'пока' })
end

g.test_failure_is_recognised_and_nothing_else_is = function()
    t.assert_equals(failure.is(failure.new(failure.TIMEOUT, 'тишина')), true)
    t.assert_equals(failure.is({ kind = 'timeout', message = 'тишина' }), false)
    t.assert_equals(failure.is('тишина'), false)
    t.assert_equals(failure.new(failure.INVALID, 'нет').status, nil)
end

g.test_failure_kinds_are_words = function()
    t.assert_equals(
        { failure.CLOSED, failure.TIMEOUT, failure.INVALID, failure.REFUSED, failure.UNREACHABLE },
        { 'closed', 'timeout', 'invalid', 'refused', 'unreachable' }
    )
end
