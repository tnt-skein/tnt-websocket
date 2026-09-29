--- Отказ WebSocket: род, текст для человека и то, чем кончилось соединение.
---
--- Отказ — пара `nil, err`, а не исключение: закрытое той стороной
--- соединение, молчащий клиент и сервер, не принявший рукопожатие, — «так
--- бывает». `err` — таблица с родом, по которому решают, что делать дальше;
--- строкой, в склейке и в журнале она — свой текст.
---
--- Тот же вид у отказа рукопожатия на стороне сервера: там он ещё
--- и отказ по договору границы HTTP роутера `tnt-router` — с числовым
--- `status`, словом `message` и заголовками `headers`, — и роутер отвечает
--- им как отказом обработчика.

local Module = {}

--- Соединение закрыто: той стороной, нами или обрывом. Код и причина — в `code`, `reason`.
Module.CLOSED = 'closed'

--- За срок ничего не пришло либо запись не дождалась очереди; соединение живо.
Module.TIMEOUT = 'timeout'

--- Отправлять нечего: текст не в UTF-8. Соединение живо, ничего не ушло.
Module.INVALID = 'invalid'

--- Рукопожатие не состоялось: сервер отказал либо ответил не по RFC 6455.
Module.REFUSED = 'refused'

--- До сервера не дошли: соединение не открылось или TLS не поднялся.
Module.UNREACHABLE = 'unreachable'

---@class TntWebsocketFailure
---@field kind string Род: closed, timeout, invalid, refused либо unreachable
---@field message string Текст для человека; его и отдаёт `tostring`
---@field code integer|nil Код закрытия (RFC 6455, §7.4)
---@field reason string|nil Причина закрытия, как её прислали
---@field status integer|nil Статус ответа: отказ рукопожатия
---@field headers table<string, string>|nil Заголовки, которых требует статус

--- Текст отказа — его слово для человека.
---@param failure TntWebsocketFailure
---@return string
local function text_of(failure)
    return failure.message
end

--- Склейка отказа со строкой с любой стороны.
---@param left any
---@param right any
---@return string
local function glued(left, right)
    return tostring(left) .. tostring(right)
end

--- Поведение всех отказов: строкой, в JSON и в склейке они — свой текст.
local Failure = { __tostring = text_of, __serialize = text_of, __concat = glued }

--- Собирает отказ.
---@param kind string Род
---@param message string Текст для человека
---@param fields table|nil Код и причина закрытия, статус и заголовки отказа
---@return TntWebsocketFailure
function Module.new(kind, message, fields)
    local failure = { kind = kind, message = message }

    for name, value in pairs(fields or {}) do
        failure[name] = value
    end

    return setmetatable(failure, Failure)
end

--- Отказ ли это пакета.
---@param value any
---@return boolean
function Module.is(value)
    return getmetatable(value) == Failure
end

return Module
