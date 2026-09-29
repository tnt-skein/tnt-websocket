--- Соединение WebSocket: сообщения туда и обратно поверх сокета.
---
--- Кадры читает отдельный файбер — читатель. Он отвечает на ping, ведёт
--- закрытие и складывает собранные сообщения в ящик, откуда их берёт
--- `receive`. Поэтому сессии, которая только шлёт, читать не нужно, чтобы
--- соединение жило: на ping ответит читатель, закрытие той стороны он
--- увидит сам. Полный ящик читателя останавливает — та сторона, которая
--- шлёт быстрее, чем сессия читает, упирается в TCP, а не в память узла.
---
--- Пишут и сессия, и читатель (pong, закрытие, ping), поэтому запись идёт
--- под замком: кадр уходит целиком, и кадры двух файберов не перемешаются.
---
--- Молчание дольше `ping_interval` — повод послать ping; молчание ещё на
--- столько же — обрыв (1006): сторона, не отвечающая на ping, мертва,
--- а TCP узнал бы об этом через часы.
---
--- Сокет закрывает тот, кто его открыл. У клиента — читатель, уходя;
--- у сервера — `http.server`, когда сессия вернула ему соединение.
---
--- Сжатие (`permessage-deflate`, `tnt.websocket.deflate`) идёт под тем же
--- замком записи, что и сама запись: словарь сжатия общий на соединение,
--- и сообщения обязаны уйти в том порядке, в каком сжимались. Разжимает
--- читатель — собранное сообщение целиком, с пределом `max_message`.

local digest = require('digest')
local fiber = require('fiber')
local utf8 = require('utf8')

local clock = require('tnt.clock')
local context = require('tnt.context')
local must = require('tnt.must')
local external = require('tnt.external')

local codes = require('tnt.websocket.codes')
local deflate_of = require('tnt.websocket.deflate')
local failure = require('tnt.websocket.failure')
local frame = require('tnt.websocket.frame')

local log = require('tnt.log').new('tnt.websocket')

local Module = {}

--- Внешние средства: случайность ключей маски и часы срока закрытия.
local source = external.install(Module, {
    random = digest.urandom,
    monotonic = clock.monotonic,
    scheduler_now = clock.scheduler_now,
})

--- Состояния соединения.
Module.OPEN = 'open'
Module.CLOSING = 'closing'
Module.CLOSED = 'closed'

--- Виды сообщений.
Module.TEXT = 'text'
Module.BINARY = 'binary'

--- Вид сообщения по коду кадра и обратно.
local KINDS = { [frame.TEXT] = Module.TEXT, [frame.BINARY] = Module.BINARY }
local OPCODES = { [Module.TEXT] = frame.TEXT, [Module.BINARY] = frame.BINARY }

---@class TntWebsocketSettings
---@field max_message integer Сколько байт в сообщении принять, не больше; у сжатого — разжатых
---@field ping_interval number Сколько секунд молчания до ping
---@field send_timeout number Сколько секунд ждать очереди записи и самой записи
---@field close_timeout number Сколько секунд ждать ответа на закрытие
---@field backlog integer Сколько непрочитанных сообщений держать в ящике
---@field compress boolean Договариваться ли о сжатии permessage-deflate

---@class TntWebsocketMessage
---@field kind string text либо binary
---@field data string Содержимое

---@class TntWebsocketConnectionOptions
---@field masking boolean Маскировать ли свои кадры: у клиента — да
---@field owned boolean Закрывать ли сокет самим: у клиента — да
---@field settings TntWebsocketSettings
---@field protocol string|nil Подпротокол, о котором договорились
---@field request table|nil Запрос рукопожатия: у сервера
---@field deflate TntWebsocketDeflate|nil Договор о сжатии; nil — сообщения несжатые

---@class TntWebsocketConnection
---@field state string open, closing либо closed
---@field protocol string|nil Подпротокол, о котором договорились
---@field compressed boolean Договорились ли о сжатии permessage-deflate
---@field request table|nil Запрос рукопожатия: у сервера
---@field closed TntWebsocketFailure|nil Чем кончилось; есть у закрытого
---@field wire TntWebsocketWire Сокет; дальше — внутреннее устройство
---@field masking boolean
---@field owned boolean
---@field settings TntWebsocketSettings
---@field squeezer TntWebsocketSqueezer|nil Сжатие своих сообщений; есть, если договорились
---@field inbox table Ящик собранных сообщений; `false` в нём — знак конца
---@field lock table Замок записи: канал на одно место
---@field done table Побудка ждущих закрытия
---@field reader table Файбер читателя
---@field sent { code: integer, reason: string }|nil Чем закрываем мы
---@field halted boolean Остановлен ли читатель
local Connection = {}
Connection.__index = Connection

--- Становится закрытым: запоминает, чем кончилось, и будит ждущих.
---@param self table
---@param code integer
---@param reason string
---@param message string
local function settle(self, code, reason, message)
    if self.state == Module.CLOSED then
        return
    end

    self.state = Module.CLOSED
    self.closed = failure.new(failure.CLOSED, message, { code = code, reason = reason })
    -- Знак конца — только в ящик с местом: ждущему в `receive` он нужен
    -- сейчас, а не по сроку, а полный ящик разбудит его и так — сообщения
    -- в нём целы, и `receive` ответит закрытием, дочитав их.
    if not self.inbox:is_full() then
        self.inbox:put(false)
    end
    self.done:broadcast()
end

--- Отказ «соединения уже нет»: у закрытого — итог, у закрывающегося — наш код.
---@param self table
---@return TntWebsocketFailure
local function gone(self)
    if self.closed ~= nil then
        return self.closed
    end

    return failure.new(
        failure.CLOSED,
        'соединение закрывается',
        { code = self.sent.code, reason = self.sent.reason }
    )
end

--- Пишет кадр под замком.
---
--- Кадр, недописанный до срока, портит поток: та сторона прочла бы его
--- хвост головой следующего. Поэтому сорванная запись закрывает соединение.
---
--- Сжатие тоже идёт под замком, и оборвать его может отмена файбера
--- в уступке между кусками работы. Замок тогда отпускается, а соединение
--- закрывается: словарь сжатия уже взял начало сообщения, которое не ушло,
--- и следующее сжатое та сторона прочла бы со ссылками в никуда. Отмена
--- от этого не теряется: файбер остаётся отменённым, и бросок повторится
--- на его следующей уступке.
---@param self table
---@param opcode integer
---@param payload string
---@param compressed boolean|nil Сжать ли сообщение
---@return true|nil sent
---@return TntWebsocketFailure|nil err
local function transmit(self, opcode, payload, compressed)
    local timeout = self.settings.send_timeout

    -- В замок кладётся код кадра: что лежит в канале, неважно, важно место.
    if not self.lock:put(opcode, timeout) then
        return nil,
            failure.new(failure.TIMEOUT, ('запись ждала очереди дольше %s с'):format(timeout))
    end

    local body, broken = payload, nil

    if compressed then
        body, broken = self.squeezer:pack(payload)
    end

    if body == nil then
        self.lock:get()
        settle(self, codes.ABNORMAL, '', broken --[[@as string]])

        return nil, self.closed
    end

    local key = self.masking and source().random(4) or nil
    local written, err = self.wire:write(frame.encode(opcode, body, key, compressed), timeout)

    self.lock:get()

    if not written then
        settle(
            self,
            codes.ABNORMAL,
            '',
            ('соединение оборвалось на записи: %s'):format(tostring(err))
        )

        return nil, self.closed
    end

    return true
end

--- Рвёт соединение из-за беды: нарушения протокола или обрыва.
---
--- Нарушителю уходит кадр закрытия с кодом и без причины: подробность —
--- для своего журнала, а не для той стороны. Обрыву (1006) кадра нет —
--- код этот в кадре не ходит, а слушать уже некому.
---@param self table
---@param trouble TntWebsocketTrouble
local function break_off(self, trouble)
    if trouble.code ~= codes.ABNORMAL then
        log.warn(
            'та сторона нарушила протокол WebSocket',
            { code = trouble.code, reason = trouble.reason }
        )

        if self.state == Module.OPEN then
            transmit(self, frame.CLOSE, frame.closing(trouble.code))
        end
    end

    settle(self, trouble.code, '', ('соединение разорвано: %s'):format(trouble.reason))
end

--- Управляющий кадр: ping, pong либо закрытие.
---@param self table
---@param got TntWebsocketFrame
local function answer(self, got)
    if got.opcode == frame.PING then
        if self.state == Module.OPEN then
            transmit(self, frame.PONG, got.payload)
        end

        return
    end

    -- Pong — ответ на наш ping: довольно того, что он пришёл.
    if got.opcode ~= frame.CLOSE then
        return
    end

    local closing, trouble = frame.closed_by(got.payload)

    if closing == nil then
        return break_off(self, trouble --[[@as TntWebsocketTrouble]])
    end

    if self.state == Module.OPEN then
        -- Ответ — эхом кода (§5.5.1); закрытию без кода отвечают без кода.
        local echo = closing.code ~= codes.NO_STATUS and closing.code or nil

        transmit(self, frame.CLOSE, frame.closing(echo))

        return settle(self, closing.code, closing.reason, 'та сторона закрыла соединение')
    end

    -- Ответ на наше закрытие: итог — то, с чем закрывали мы.
    return settle(self, self.sent.code, self.sent.reason, 'соединение закрыто')
end

--- Отдаёт собранное сообщение в ящик.
---
--- Сжатое сперва разжимается: и UTF-8 текста, и предел `max_message`
--- относятся к сообщению, а не к его сжатому виду.
---@param self table
---@param opcode integer
---@param payload string
---@param compressed boolean Поднят ли RSV1 у первого кадра
local function deliver(self, opcode, payload, compressed)
    local data = payload

    if compressed then
        local unpacked, trouble = deflate_of.unpack(payload, self.settings.max_message)

        if unpacked == nil then
            return break_off(self, trouble --[[@as TntWebsocketTrouble]])
        end

        data = unpacked
    end

    if opcode == frame.TEXT and utf8.len(data) == nil then
        return break_off(self, frame.trouble(codes.INVALID_DATA, 'текст сообщения не в UTF-8'))
    end

    -- После нашего закрытия сообщений той стороны уже никто не ждёт.
    if self.state == Module.OPEN then
        self.inbox:put({ kind = KINDS[opcode], data = data })
    end
end

--- Кадр данных: начало, продолжение либо всё сообщение сразу.
---@param self table
---@param got TntWebsocketFrame
---@param partial table|nil Недособранное сообщение
---@return table|nil partial Что осталось недособранным
local function gather(self, got, partial)
    if got.opcode == frame.CONTINUATION then
        if partial == nil then
            break_off(
                self,
                frame.trouble(codes.PROTOCOL_ERROR, 'продолжение без начала сообщения')
            )

            return nil
        end

        -- Пустые части не копятся: их поток иначе рос бы в памяти без
        -- предела, ведь места под сообщение они не занимают.
        if got.payload ~= '' then
            table.insert(partial.parts, got.payload)
        end

        partial.size = partial.size + #got.payload
    elseif partial ~= nil then
        break_off(
            self,
            frame.trouble(codes.PROTOCOL_ERROR, 'новое сообщение посреди прежнего')
        )

        return nil
    else
        partial = { opcode = got.opcode, compressed = got.compressed, parts = { got.payload }, size = #got.payload }
    end

    if not got.fin then
        return partial
    end

    deliver(self, partial.opcode, table.concat(partial.parts), partial.compressed)

    return nil
end

--- Цикл читателя: кадр за кадром, пока соединение не закрыто.
---@param self table
local function listen(self)
    local settings = self.settings
    local rules = {
        masked = not self.masking,
        deflate = self.compressed,
        idle = settings.ping_interval,
        timeout = settings.ping_interval,
        room = settings.max_message,
    }
    local partial = nil
    local pinged = false

    while self.state ~= Module.CLOSED do
        rules.room = settings.max_message - (partial and partial.size or 0)

        local got, trouble = frame.read(self.wire, rules)

        if got ~= nil then
            pinged = false

            if got.opcode >= frame.CLOSE then
                answer(self, got)
            else
                partial = gather(self, got, partial)
            end
        elseif trouble ~= frame.SILENT then
            break_off(self, trouble --[[@as TntWebsocketTrouble]])
        elseif pinged then
            local silence = ('та сторона не ответила на ping за %s с'):format(
                settings.ping_interval
            )

            break_off(self, frame.trouble(codes.ABNORMAL, silence))
        else
            pinged = true

            if self.state == Module.OPEN then
                transmit(self, frame.PING, '')
            end
        end
    end
end

--- Заводит читателя.
---
--- Читатель живёт в контексте того, кто завёл соединение (`tnt-context`):
--- сам `fiber.new` хранилища родителя не наследует, и запись о нарушении
--- протокола ушла бы в журнал без опознавателя запроса рукопожатия.
---@param self table
local function start(self)
    local reader = fiber.new(context.bind(function()
        local ok, err = pcall(listen, self)

        -- Сюда приходят отмена (так читателя останавливают) и брошенное
        -- сокетом, закрытым под ним: соединению в обоих случаях конец.
        if not ok then
            settle(self, codes.ABNORMAL, '', ('чтение оборвалось: %s'):format(tostring(err)))
        end

        if self.owned then
            self.wire:close()
        end
    end))

    reader:set_joinable(true)
    reader:name('websocket')
    self.reader = reader
end

--- Ждёт сообщение.
---
--- Сообщения, пришедшие до закрытия, отдаются и после него: ящик
--- дочитывается до конца, и только потом `receive` отвечает закрытием.
---@param timeout number|nil Сколько секунд ждать; без срока — пока не придёт
---@return TntWebsocketMessage|nil message
---@return TntWebsocketFailure|nil err `closed` либо `timeout`
function Connection:receive(timeout)
    must.at(2).optional.non_negative(timeout, 'срок ожидания сообщения')

    if self.state == Module.CLOSED and self.inbox:is_empty() then
        return nil, self.closed
    end

    local message = self.inbox:get(timeout)

    if message then
        return message
    end

    if message == false then
        return nil, self.closed
    end

    return nil, failure.new(failure.TIMEOUT, ('сообщения нет за %s с'):format(timeout))
end

--- Шлёт сообщение одним кадром.
---
--- Текст обязан быть в UTF-8 (§5.6): та сторона рвёт соединение на тексте,
--- который не прочесть. Поэтому негодный текст не уходит вовсе — отказ
--- `invalid`, а соединение остаётся живым.
---
--- Сжимается всякое непустое сообщение, если о сжатии договорились.
--- Пустое уходит несжатым: сжимать в нём нечего, а RSV1 — знак сообщения,
--- а не соединения, и несжатое между сжатыми законно (RFC 7692, §6).
---@param data string Содержимое
---@param kind string|nil text либо binary; по умолчанию text
---@return true|nil sent
---@return TntWebsocketFailure|nil err `closed`, `timeout` либо `invalid`
function Connection:send(data, kind)
    local caller = must.at(2)

    caller.string(data, 'сообщение')
    caller.optional.one_of(kind, 'вид сообщения', { Module.TEXT, Module.BINARY })

    local chosen = kind or Module.TEXT

    if self.state ~= Module.OPEN then
        return nil, gone(self)
    end

    if chosen == Module.TEXT and utf8.len(data) == nil then
        return nil,
            failure.new(
                failure.INVALID,
                'текст сообщения не в UTF-8: такое шлют видом binary'
            )
    end

    return transmit(self, OPCODES[chosen] --[[@as integer]], data, self.compressed and data ~= '')
end

--- Ждёт ответа на наше закрытие, но не дольше `close_timeout` от отправки
--- кадра.
---
--- Срок — миг по настоящим часам, а остаток, уходящий в ожидание, считается
--- от времени планировщика (правило сроков `tnt-clock`): ожидание отсчитывает
--- его от той же отметки цикла событий и кончается в срок, сколько бы ни шла
--- перед ним работа без уступки. Срок, отданный ожиданию целиком, отсчитался
--- бы от отставшей отметки и кончился раньше на всю эту работу.
---
--- Истечение решают настоящие часы, и решают после каждого пробуждения:
--- ожидание будит не только ответ той стороны, но и чужой `fiber:wakeup`,
--- а разбуженное до срока ждёт остаток. Закрытие той стороны, пришедшее,
--- пока наш кадр ждал очереди записи, уже кончило соединение — цикл
--- не начинается вовсе.
---@param self table
local function await_answer(self)
    local clocks = source()
    local deadline = clocks.monotonic() + self.settings.close_timeout

    while self.state ~= Module.CLOSED and clocks.monotonic() < deadline do
        self.done:wait(deadline - clocks.scheduler_now())
    end
end

--- Закрывает соединение: кадр закрытия и ответ той стороны (§7.1.2).
---
--- Ответа ждёт `close_timeout` от отправки кадра; не дождалось — закрыто
--- всё равно. Негодный код или причина — бросок на строке вызывающего
--- (`frame.check_closing`).
---@param code integer|nil Код закрытия; по умолчанию 1000
---@param reason string|nil Причина; по умолчанию пустая
---@return true
function Connection:close(code, reason)
    local chosen = code or codes.NORMAL
    local said = reason or ''

    frame.check_closing(chosen, said)

    if self.state == Module.OPEN then
        self.state = Module.CLOSING
        self.sent = { code = chosen, reason = said }

        if transmit(self, frame.CLOSE, frame.closing(chosen, said)) then
            await_answer(self)
        end

        settle(
            self,
            chosen,
            said,
            'соединение закрыто: та сторона не ответила на закрытие'
        )
    end

    Module.halt(self)

    return true
end

--- Открыто ли соединение: можно ли слать и ждать сообщений.
---@return boolean
function Connection:is_open()
    return self.state == Module.OPEN
end

--- Заводит соединение поверх сокета, на котором уже прошло рукопожатие.
---@param wire TntWebsocketWire
---@param options TntWebsocketConnectionOptions
---@return TntWebsocketConnection
function Module.new(wire, options)
    local self = setmetatable({
        wire = wire,
        masking = options.masking,
        owned = options.owned,
        settings = options.settings,
        protocol = options.protocol,
        request = options.request,
        compressed = options.deflate ~= nil,
        squeezer = options.deflate and deflate_of.new(options.deflate),
        state = Module.OPEN,
        inbox = fiber.channel(options.settings.backlog),
        lock = fiber.channel(1),
        done = fiber.cond(),
        halted = false,
    }, Connection)

    start(self)

    return self
end

--- Останавливает соединение: закрыто, читатель ушёл.
---
--- Звать не из читателя. После возврата сокета не касается ни один
--- файбер соединения — у сервера его сразу закрывает `http.server`.
---@param connection TntWebsocketConnection
function Module.halt(connection)
    settle(connection, codes.ABNORMAL, '', 'соединение закрыто')

    if connection.halted then
        return
    end

    connection.halted = true
    connection.reader:cancel()
    connection.reader:join()
end

return Module
