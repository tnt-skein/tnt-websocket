--- Сжатие сообщений: расширение `permessage-deflate` (RFC 7692).
---
--- О сжатии договариваются в рукопожатии заголовком
--- `Sec-WebSocket-Extensions`: клиент предлагает, сервер принимает первое
--- годное предложение и называет в ответе, на чём сошлись. Сжатое
--- сообщение несёт бит RSV1 в первом кадре; данные — DEFLATE без обёртки
--- (`raw` у `tnt-compress`), сброшенный `Z_SYNC_FLUSH`, с отрезанным
--- хвостом `00 00 ff ff` (§7.2.1). Получатель приставляет хвост обратно
--- и разжимает (§7.2.2).
---
--- Своё сжатие держит словарь от сообщения к сообщению, пока та сторона
--- не попросила иного (`*_no_context_takeover`): повторы в JSON соседних
--- сообщений сжимаются ссылкой назад. От той стороны договор требует
--- обратного всегда — каждое её сообщение сжато с пустым словарём.
--- Поэтому разжатие у нас — свой поток на каждое сообщение с пределом
--- `max_message`: предел потока `tnt-compress` считает разжатое всех
--- кусков вместе, и поток на всё соединение упёрся бы в предел через
--- мегабайт разговора. А без предела килобайт сжатого разжался бы
--- в гигабайт в памяти узла.
---
--- Окно сжатия у `tnt-compress` одно — 15 бит, поэтому предложение
--- с `server_max_window_bits` меньше 15 сервер отклоняет: сжатое нашим
--- окном та сторона с меньшим не разожмёт. Окно той стороны любое:
--- разжатие окном в 15 бит читает и сжатое меньшим.

local compress = require('tnt.compress')

local codes = require('tnt.websocket.codes')
local frame = require('tnt.websocket.frame')

local Module = {}

--- Имя расширения.
Module.NAME = 'permessage-deflate'

--- Предложение клиента: сжатие, и та сторона словаря не держит.
Module.OFFER = Module.NAME .. '; server_no_context_takeover'

--- Хвост сброса: пустой несжатый блок DEFLATE, который отправитель
--- отрезает, а получатель приставляет обратно.
local TAIL = '\0\0\255\255'

--- Окно в битах, как его пишут в параметре: десятичным от 8 до 15 без
--- ведущих нулей (§7.1.2).
local WINDOWS = {
    ['8'] = true,
    ['9'] = true,
    ['10'] = true,
    ['11'] = true,
    ['12'] = true,
    ['13'] = true,
    ['14'] = true,
    ['15'] = true,
}

--- Окно, которым сжимает `tnt-compress`.
local WIDEST = '15'

---@class TntWebsocketDeflate Договор о сжатии
---@field takeover boolean Держит ли наше сжатие словарь от сообщения к сообщению

---@class TntWebsocketOffer Предложение расширения из заголовка
---@field name string Имя расширения
---@field params table<string, string|true> Параметры; без значения — true
---@field repeated boolean Назван ли какой-то параметр дважды

--- Параметр без значения.
---@param value string|true
---@return boolean
local function bare(value)
    return value == true
end

--- Окно, которым сжимаем мы.
---@param value string|true
---@return boolean
local function widest(value)
    return value == WIDEST
end

--- Окно той стороны: любое годное.
---@param value string|true
---@return boolean
local function window(value)
    return WINDOWS[value] == true
end

--- Окно той стороны либо ничего: клиент так говорит, что понимает
--- `client_max_window_bits` в ответе.
---@param value string|true
---@return boolean
local function window_or_bare(value)
    return value == true or window(value)
end

--- Параметры предложения клиента, с которыми сервер его принимает,
--- и правило значения каждого (§7.1).
local OFFERED = {
    server_no_context_takeover = bare,
    client_no_context_takeover = bare,
    server_max_window_bits = widest,
    client_max_window_bits = window_or_bare,
}

--- Параметры ответа сервера на наше предложение. `client_max_window_bits`
--- среди них нет: мы его не предлагали, и сузить своё окно нам нечем.
local ANSWERED = {
    server_no_context_takeover = bare,
    client_no_context_takeover = bare,
    server_max_window_bits = window,
}

--- Параметр расширения: имя и значение; без значения — `true`.
---@param part string
---@return string name
---@return string|true value
local function param_of(part)
    local at = part:find('=')

    if at == nil then
        return part, true
    end

    return part:sub(-#part, at - 1), part:sub(at + 1)
end

--- Предложения расширений из заголовка — по порядку предпочтения.
---
--- Пробелы вокруг `,`, `;` и `=` законны, а значение в кавычках —
--- quoted-string, внутри которого по RFC 6455 (§9.1) та же лексема.
--- В самих лексемах нет ни пробелов, ни кавычек, поэтому снять их разом —
--- то же, что разобрать по грамматике. Пустые элементы списка законны
--- и пропускаются (RFC 9110, §5.6.1).
---@param value string
---@return TntWebsocketOffer[]
local function offers_of(value)
    local offers = {}
    local text = value:gsub('[%s"]', '')

    for _, item in ipairs(text:split(',')) do
        if item ~= '' then
            local parts = item:split(';')
            local offer = { name = parts[1], params = {}, repeated = false }

            for index = 2, #parts do
                local name, given = param_of(parts[index])

                offer.repeated = offer.repeated or offer.params[name] ~= nil
                offer.params[name] = given
            end

            table.insert(offers, offer)
        end
    end

    return offers
end

--- Годно ли предложение: только знакомые параметры, каждый однажды
--- и с годным значением. Иное предложение отклоняется целиком (§7).
---@param offer TntWebsocketOffer
---@param rules table<string, fun(value: string|true): boolean>
---@return boolean
local function fits(offer, rules)
    -- Одним выражением, а не ранними `return false`: результат идёт только
    -- в условие, и мутант `return nil` на месте `false` был бы неотличим.
    local fit = offer.name == Module.NAME and not offer.repeated

    for name, value in pairs(offer.params) do
        local rule = rules[name]

        fit = fit and rule ~= nil and rule(value)
    end

    return fit
end

--- Ответ сервера на предложения клиента: первое годное.
---
--- В ответе всегда `client_no_context_takeover`: сообщения клиента
--- разжимаются каждое своим потоком (шапка модуля). `server_no_context_takeover`
--- и окно ответ повторяет, если клиент их назвал, — так сервер принимает
--- эти параметры (§7.1.1.1, §7.1.2.1).
---@param value string|nil Заголовок `Sec-WebSocket-Extensions` запроса
---@return TntWebsocketDeflate|nil agreement Договор; nil — сжатия нет
---@return string|nil answer Заголовок `Sec-WebSocket-Extensions` ответа
function Module.accept(value)
    for _, offer in ipairs(offers_of(value or '')) do
        if fits(offer, OFFERED) then
            local params = offer.params
            local answer = { Module.NAME, 'client_no_context_takeover' }

            if params.server_no_context_takeover ~= nil then
                table.insert(answer, 'server_no_context_takeover')
            end

            if params.server_max_window_bits ~= nil then
                table.insert(answer, 'server_max_window_bits=' .. WIDEST)
            end

            return { takeover = params.server_no_context_takeover == nil }, table.concat(answer, '; ')
        end
    end

    return nil
end

--- Договор по ответу сервера на наше предложение.
---
--- Годен ответ ровно с одним расширением — нашим, со знакомыми
--- параметрами и с `server_no_context_takeover`, о котором мы просили:
--- без него сервер держал бы словарь, а разжатие у нас с пустым.
---@param value string Заголовок `Sec-WebSocket-Extensions` ответа
---@return TntWebsocketDeflate|nil agreement nil — ответ не по RFC 7692
function Module.agreed(value)
    local answers = offers_of(value)

    if #answers ~= 1 then
        return nil
    end

    local answer = answers[1] --[[@as TntWebsocketOffer]]

    if not fits(answer, ANSWERED) or answer.params.server_no_context_takeover == nil then
        return nil
    end

    return { takeover = answer.params.client_no_context_takeover == nil }
end

--- Сжатие сообщений одного соединения.
---@class TntWebsocketSqueezer
---@field takeover boolean Держать ли словарь от сообщения к сообщению
---@field deflater TntCompressDeflater|nil Поток сжатия, пока словарь держится
local Squeezer = {}
Squeezer.__index = Squeezer

--- Формат DEFLATE без обёртки.
local RAW = { format = 'raw' }

--- Сжатие с отрезанным хвостом; бросает, как бросает сжатие.
---@param self TntWebsocketSqueezer
---@param payload string
---@return string
local function squeezed(self, payload)
    local deflater = self.deflater or compress.deflater(RAW)
    local packed = deflater:flush(payload)

    if self.takeover then
        self.deflater = deflater
    else
        deflater:finish()
    end

    -- Начало среза — `-#packed`: у единицы мутант `0` дал бы тот же срез.
    return packed:sub(-#packed, -#TAIL - 1)
end

--- Сжимает сообщение: сброс и отрезанный хвост (§7.2.1).
---
--- Звать под замком записи: поток сжатия — одному файберу, а сообщения
--- обязаны уйти в том порядке, в каком сжимались, — иначе ссылки назад
--- у той стороны укажут не туда. Без словаря поток на каждое сообщение
--- свой, и память zlib отдаётся сразу.
---
--- Сжатие уступает между кусками работы, и в уступке его обрывает отмена
--- файбера. Брошенное отдаётся отказом, а не летит сквозь писателя: тому
--- надо отпустить замок записи и закрыть соединение — словарь уже взял
--- начало сообщения, которое не уйдёт.
---@param payload string Непустое сообщение
---@return string|nil packed
---@return string|nil broken Почему сжатие оборвалось
function Squeezer:pack(payload)
    local ok, packed = pcall(squeezed, self, payload)

    if not ok then
        return nil, ('сжатие сообщения оборвалось: %s'):format(tostring(packed))
    end

    return packed
end

--- Сжатие по договору.
---@param agreement TntWebsocketDeflate
---@return TntWebsocketSqueezer
function Module.new(agreement)
    return setmetatable({ takeover = agreement.takeover }, Squeezer)
end

--- Разжимает сообщение той стороны: хвост обратно и разжатие не больше
--- предела (§7.2.2).
---
--- Разжатое больше предела — 1009, как у несжатого; испорченное — 1007:
--- сообщение пришло, а прочесть его нельзя. Сообщение, сжатое с концом
--- потока DEFLATE (BFINAL, §7.2.3.4), — тоже 1007: хвост ложится за конец
--- потока, а `raw` лишнего после конца не прощает.
---@param payload string Сжатое сообщение, собранное из кадров
---@param limit integer Сколько байт разжатого принять
---@return string|nil data
---@return TntWebsocketTrouble|nil trouble
function Module.unpack(payload, limit)
    local inflater = compress.inflater({ format = 'raw', limit = limit })
    local data, err = inflater:write(payload .. TAIL)

    -- Только чтобы отдать память zlib сразу: поток со сбросом до конца
    -- не доходит, и отказ `truncated` здесь ожидаем.
    inflater:finish()

    if data ~= nil then
        return data
    end

    ---@cast err TntCompressFailure

    if err.kind == compress.TOO_LARGE then
        return nil,
            frame.trouble(
                codes.MESSAGE_TOO_BIG,
                ('разжатое сообщение длиннее %d байт'):format(limit)
            )
    end

    return nil,
        frame.trouble(
            codes.INVALID_DATA,
            ('сжатое сообщение не разжимается: %s'):format(tostring(err))
        )
end

return Module
