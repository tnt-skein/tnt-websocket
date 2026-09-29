--- Кадр WebSocket: запись, разбор и маска (RFC 6455, §5).
---
--- Кадр — два байта головы, длина, ключ маски и полезная нагрузка:
---
---     FIN RSV1-3 код | MASK длина(7) | длина(16|64)? | ключ(4)? | данные
---
--- Разбор строгий, и каждое нарушение — отказ с кодом закрытия, а не
--- догадка: зарезервированные биты без расширения, незнакомый код кадра,
--- управляющий кадр частями или длиннее 125 байт, длина с поднятым старшим
--- битом, кадр клиента без маски и кадр сервера с маской — 1002; длина
--- кадра данных больше, чем осталось места под сообщение, — 1009, и данные
--- такого кадра не читаются вовсе: иначе заявленные гигабайты легли бы
--- в память узла раньше отказа.
---
--- Из зарезервированных битов законен только RSV1 — знак сжатого
--- сообщения, когда о `permessage-deflate` договорились (RFC 7692, §6).
--- Его несёт первый кадр сообщения данных; у продолжения и у управляющего
--- кадра он — нарушение: сжато сообщение, а не кадр.
---
--- Кадры пишутся целиком, без деления на части: сообщение уходит одним
--- кадром, и та сторона собирает его без продолжений. Маску ставит только
--- клиент — у сервера её не бывает (§5.1).

local bit = require('bit')
local ffi = require('ffi')
local utf8 = require('utf8')

local must = require('tnt.must')

local codes = require('tnt.websocket.codes')

local Module = {}

--- Коды кадров (§5.2).
Module.CONTINUATION = 0x0
Module.TEXT = 0x1
Module.BINARY = 0x2
Module.CLOSE = 0x8
Module.PING = 0x9
Module.PONG = 0xA

--- Сколько байт данных у управляющего кадра, не больше (§5.5).
Module.MAX_CONTROL = 125

--- Сколько байт причины влезает в кадр закрытия: два байта уходят коду.
Module.MAX_REASON = 123

--- Длина, записанная в семь бит головы; дальше — отдельным полем.
local SHORT = 125

--- Знак длины в следующих двух байтах.
local WIDE = 126

--- Знак длины в следующих восьми байтах.
local HUGE = 127

--- Бит последнего кадра сообщения и бит маски.
local FIN = 0x80
local MASKED = 0x80

--- Бит сжатого сообщения (RFC 7692, §6) и все зарезервированные биты.
local RSV1 = 0x40
local RESERVED = 0x70

--- Коды кадров, которые понимает RFC 6455; остальные зарезервированы.
local KNOWN = {
    [Module.CONTINUATION] = true,
    [Module.TEXT] = true,
    [Module.BINARY] = true,
    [Module.CLOSE] = true,
    [Module.PING] = true,
    [Module.PONG] = true,
}

--- Коды кадров, которые начинают сообщение данных: только они несут RSV1.
local DATA = {
    [Module.TEXT] = true,
    [Module.BINARY] = true,
}

---@class TntWebsocketFrame
---@field fin boolean Последний ли кадр сообщения
---@field compressed boolean Поднят ли RSV1: сообщение сжато
---@field opcode integer Код кадра
---@field payload string Данные, уже без маски

---@class TntWebsocketTrouble
---@field code integer Код закрытия, с которым рвать соединение
---@field reason string Что случилось; уходит в журнал и в кадр закрытия

---@class TntWebsocketRules
---@field masked boolean Должны ли входящие кадры быть с маской: у сервера — да
---@field deflate boolean|nil Договорились ли о сжатии: законен ли RSV1
---@field room integer Сколько байт данных ещё можно принять в сообщение
---@field idle number Сколько секунд ждать начала кадра
---@field timeout number Сколько секунд ждать каждой следующей части кадра

--- Беда, с которой соединение рвут.
---@param code integer
---@param reason string
---@return TntWebsocketTrouble
function Module.trouble(code, reason)
    return { code = code, reason = reason }
end

--- Знак «до срока не пришло ни байта»: кадра нет, но соединение не порвано.
---
--- Сверяется по тождеству, а не по коду: молчание — повод прислать ping,
--- а не закрывать соединение, и путать его с обрывом нельзя.
Module.SILENT = Module.trouble(codes.ABNORMAL, 'до срока не пришло ни байта')

--- Число байтами старшим вперёд, ровно `width` байт.
---@param value integer
---@param width integer
---@return string
function Module.big_endian(value, width)
    local text = ''

    for _ = 1, width do
        text = string.char(value % 256) .. text
        value = math.floor(value / 256)
    end

    return text
end

--- Число из байтов старшим вперёд.
---@param bytes string
---@return integer
function Module.number_of(bytes)
    local value = 0

    for at = 1, #bytes do
        value = value * 256 + bytes:byte(at)
    end

    return value
end

--- Накладывает маску: исключающее «или» с ключом по кругу (§5.3).
---
--- Та же операция и снимает маску. Байты читаются `string.byte`,
--- а собираются в буфер FFI: склейка строк по байту на мегабайтном
--- сообщении стоила бы квадрата.
---@param payload string
---@param key string Четыре байта ключа
---@return string
function Module.mask(payload, key)
    local size = #payload
    local out = ffi.new('uint8_t[?]', size) --[[@as integer[] ]]
    -- Номер байта считается с единицы, поэтому четвёртый байт ключа
    -- ложится на остаток ноль.
    local keys = { [0] = key:byte(4), key:byte(1), key:byte(2), key:byte(3) }

    for at = 1, size do
        out[at - 1] = bit.bxor(payload:byte(at), keys[bit.band(at, 3)] --[[@as integer]])
    end

    return ffi.string(out, size)
end

--- Записывает кадр целиком: одно сообщение — один кадр.
---@param opcode integer Код кадра
---@param payload string Данные
---@param key string|nil Ключ маски; есть только у клиента
---@param compressed boolean|nil Сжато ли сообщение: поднять RSV1
---@return string
function Module.encode(opcode, payload, key, compressed)
    local size = #payload
    local mark = key ~= nil and MASKED or 0x00
    local head = string.char(bit.bor(FIN, compressed and RSV1 or 0x00, opcode))

    if size <= SHORT then
        head = head .. string.char(bit.bor(mark, size))
    elseif size <= 0xFFFF then
        head = head .. string.char(bit.bor(mark, WIDE)) .. Module.big_endian(size, 2)
    else
        head = head .. string.char(bit.bor(mark, HUGE)) .. Module.big_endian(size, 8)
    end

    if key == nil then
        return head .. payload
    end

    return head .. key .. Module.mask(payload, key)
end

--- Данные кадра закрытия: код и причина (§5.5.1).
---
--- Без кода — пустые данные: так отвечают на закрытие, пришедшее без кода.
---@param code integer|nil
---@param reason string|nil
---@return string
function Module.closing(code, reason)
    if code == nil then
        return ''
    end

    return Module.big_endian(code, 2) .. (reason or '')
end

--- Проверяет код и причину закрытия: код из тех, что ходят в кадре,
--- причина — UTF-8 не длиннее 123 байт.
---
--- Негодные — ошибка программиста и бросок на строке того, кто закрывает:
--- он на два кадра выше — проверку зовёт закрытие соединения. Зовёт её
--- и закрытие всех сессий конечной точки — до того, как тронуто хоть одно
--- соединение: иначе негодный код всплыл бы в файбере, закрывающем
--- соединение, а не у вызывающего.
---@param code any
---@param reason any
function Module.check_closing(code, reason)
    local caller = must.at(3)

    caller.integer(code, 'код закрытия')
    caller.string(reason, 'причина закрытия')

    -- Текст — в своей строке, а бросок — одной: уровень на строке
    -- разбитого вызова генератор мутантов не видит.
    if not codes.sendable(code) then
        local message = ('код закрытия %d в кадре не ходит: годятся 1000–1003, 1007–1014 и 3000–4999'):format(
            code
        )

        error(message, 3)
    end

    if #reason > Module.MAX_REASON or utf8.len(reason) == nil then
        local message = ('причина закрытия — строка UTF-8 не длиннее %d байт'):format(
            Module.MAX_REASON
        )

        error(message, 3)
    end
end

--- Код и причина из данных пришедшего кадра закрытия.
---
--- Пустые данные — законное закрытие без кода, оно читается как 1005.
--- Один байт, негодный код и причина не в UTF-8 — нарушение протокола.
---@param payload string
---@return { code: integer, reason: string }|nil closing
---@return TntWebsocketTrouble|nil trouble
function Module.closed_by(payload)
    if payload == '' then
        return { code = codes.NO_STATUS, reason = '' }
    end

    if #payload < 2 then
        return nil, Module.trouble(codes.PROTOCOL_ERROR, 'кадр закрытия в один байт')
    end

    -- Начало среза — `-#payload`: у единицы мутанты `0` и `1-1` дали бы
    -- тот же срез.
    local code = Module.number_of(payload:sub(-#payload, 2))
    local reason = payload:sub(3)

    if not codes.sendable(code) then
        return nil,
            Module.trouble(
                codes.PROTOCOL_ERROR,
                ('код закрытия %d в кадре не ходит'):format(code)
            )
    end

    if utf8.len(reason) == nil then
        return nil, Module.trouble(codes.INVALID_DATA, 'причина закрытия не в UTF-8')
    end

    return { code = code, reason = reason }
end

--- Читает ровно `size` байт в срок.
---
--- Сокет отдаёт `nil` на истёкший срок и на ошибку, а на конец потока —
--- то, что успело прийти, короче просимого. Второе значение говорит,
--- кончился ли поток: молчание и обрыв для начала кадра — разное.
--- У молчания второго значения нет вовсе: `false` там неотличимо от `nil`.
---@param wire table Сокет: `read(size, timeout)`
---@param size integer
---@param timeout number
---@return string|nil piece
---@return boolean|nil ended Поток кончился раньше, чем пришло просимое
local function exactly(wire, size, timeout)
    local piece = wire:read(size, timeout)

    if piece == nil then
        return nil
    end

    if #piece < size then
        return nil, true
    end

    return piece
end

--- Беда посреди кадра: кадр не пришёл целиком — соединение порвано.
---@return TntWebsocketTrouble
local function cut_short()
    return Module.trouble(
        codes.ABNORMAL,
        'кадр не пришёл целиком: соединение оборвано или молчит'
    )
end

--- Длина данных кадра по семи битам головы и полю за ними.
---@param wire table
---@param short integer Семь бит длины
---@param rules TntWebsocketRules
---@return integer|nil size
---@return TntWebsocketTrouble|nil trouble
local function length_of(wire, short, rules)
    if short <= SHORT then
        return short
    end

    local wide = short == WIDE
    local field = exactly(wire, wide and 2 or 8, rules.timeout)

    if field == nil then
        return nil, cut_short()
    end

    -- Старший бит длины в восемь байт обязан быть нулём (§5.2): иначе
    -- длина отрицательна для тех, кто читает её знаковым числом.
    if not wide and field:byte(1) > 0x7F then
        return nil,
            Module.trouble(codes.PROTOCOL_ERROR, 'длина кадра с поднятым старшим битом')
    end

    return Module.number_of(field)
end

--- Что не так с головой кадра, если что-то не так.
---@param first integer Первый байт головы
---@param second integer Второй байт головы
---@param rules TntWebsocketRules
---@return string|nil reason
local function malformed(first, second, rules)
    local opcode = bit.band(first, 0x0F)
    local reserved = bit.band(first, RESERVED)

    if not KNOWN[opcode] then
        return ('незнакомый код кадра %d'):format(opcode)
    end

    if reserved ~= 0x00 and not (reserved == RSV1 and rules.deflate) then
        return 'зарезервированные биты кадра без расширения'
    end

    if reserved ~= 0x00 and not DATA[opcode] then
        return 'бит сжатия RSV1 у продолжения сообщения или управляющего кадра'
    end

    if (bit.band(second, MASKED) ~= 0x00) ~= rules.masked then
        return rules.masked and 'кадр клиента без маски' or 'кадр сервера с маской'
    end

    -- Управляющие кадры — коды 8 и выше.
    if bit.band(opcode, 0x08) ~= 0x00 then
        if bit.band(first, FIN) == 0x00 or bit.band(second, 0x7F) > Module.MAX_CONTROL then
            return 'управляющий кадр частями или длиннее 125 байт'
        end
    end

    return nil
end

--- Читает кадр.
---
--- Начала кадра ждёт `rules.idle`: до срока не пришло ни байта — знак
--- `SILENT`, соединение цело. Поток кончился до начала кадра — обрыв
--- без закрытия. Каждая следующая часть кадра ждётся `rules.timeout`.
---@param wire table Сокет: `read(size, timeout)`
---@param rules TntWebsocketRules
---@return TntWebsocketFrame|nil frame
---@return TntWebsocketTrouble|nil trouble Беда либо знак `SILENT`
function Module.read(wire, rules)
    local head, ended = exactly(wire, 2, rules.idle)

    if head == nil then
        if ended then
            return nil,
                Module.trouble(
                    codes.ABNORMAL,
                    'та сторона закрыла соединение без кадра закрытия'
                )
        end

        return nil, Module.SILENT
    end

    local first, second = head:byte(1), head:byte(2)
    local reason = malformed(first, second, rules)

    if reason ~= nil then
        return nil, Module.trouble(codes.PROTOCOL_ERROR, reason)
    end

    local size, trouble = length_of(wire, bit.band(second, 0x7F), rules)

    if size == nil then
        return nil, trouble
    end

    local opcode = bit.band(first, 0x0F)

    -- Место под сообщение считают только кадры данных: ping посреди
    -- почти собранного сообщения — законный кадр, и длина у него своя,
    -- до 125 байт.
    if opcode < Module.CLOSE and size > rules.room then
        return nil,
            Module.trouble(codes.MESSAGE_TOO_BIG, ('сообщение длиннее %d байт'):format(rules.room))
    end

    local key = nil

    if rules.masked then
        key = exactly(wire, 4, rules.timeout)

        if key == nil then
            return nil, cut_short()
        end
    end

    -- Пустые данные читаются тем же вызовом: сокет отдаёт пустую строку
    -- сразу, не дожидаясь срока.
    local payload = exactly(wire, size, rules.timeout)

    if payload == nil then
        return nil, cut_short()
    end

    if key ~= nil then
        payload = Module.mask(payload, key)
    end

    return {
        fin = bit.band(first, FIN) ~= 0x00,
        compressed = bit.band(first, RSV1) ~= 0x00,
        opcode = opcode,
        payload = payload,
    }
end

return Module
