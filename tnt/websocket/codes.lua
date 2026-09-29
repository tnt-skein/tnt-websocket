--- Коды закрытия соединения (RFC 6455, §7.4).
---
--- Код едет в кадре закрытия и говорит той стороне, почему разговор
--- кончен. Годятся не все числа: 1004–1006 и 1015 зарезервированы и в кадре
--- не ходят вовсе (1005 и 1006 — только слова для «кода не прислали»
--- и «оборвалось без закрытия»), 1016–2999 держит за собой IANA, а 3000–4999
--- отданы библиотекам и приложениям. Кадр с негодным кодом — нарушение
--- протокола, и отвечают на него разрывом с 1002.

local Module = {}

--- Разговор окончен как положено.
Module.NORMAL = 1000

--- Сторона уходит: сервер гасится, вкладку браузера закрыли.
Module.GOING_AWAY = 1001

--- Та сторона нарушила протокол.
Module.PROTOCOL_ERROR = 1002

--- Пришли данные того вида, которого эта сторона не принимает.
Module.UNSUPPORTED_DATA = 1003

--- Кадр закрытия пришёл без кода. В кадре не ходит.
Module.NO_STATUS = 1005

--- Соединение оборвалось без кадра закрытия. В кадре не ходит.
Module.ABNORMAL = 1006

--- Текст сообщения не в UTF-8.
Module.INVALID_DATA = 1007

--- Сообщение нарушает правила этой стороны.
Module.POLICY_VIOLATION = 1008

--- Сообщение больше, чем эта сторона готова принять.
Module.MESSAGE_TOO_BIG = 1009

--- Сервер не согласился на расширение, без которого клиент не может.
Module.MANDATORY_EXTENSION = 1010

--- У этой стороны что-то сломалось посреди разговора.
Module.INTERNAL_ERROR = 1011

--- Сервер перезапускается; переподключаться стоит.
Module.SERVICE_RESTART = 1012

--- Сервер перегружен; переподключаться стоит позже.
Module.TRY_AGAIN_LATER = 1013

--- Первый код, отданный библиотекам и приложениям.
local OWN_FIRST = 3000

--- Последний код, отданный библиотекам и приложениям.
local OWN_LAST = 4999

--- Коды протокола, которые ходят в кадре закрытия.
---
--- 1014 («Bad Gateway») внесён в реестр IANA вслед за RFC 6455 наравне
--- с 1012 и 1013; своих имён у него здесь нет, но кадр с ним законен.
local REGISTERED = {
    [Module.NORMAL] = true,
    [Module.GOING_AWAY] = true,
    [Module.PROTOCOL_ERROR] = true,
    [Module.UNSUPPORTED_DATA] = true,
    [Module.INVALID_DATA] = true,
    [Module.POLICY_VIOLATION] = true,
    [Module.MESSAGE_TOO_BIG] = true,
    [Module.MANDATORY_EXTENSION] = true,
    [Module.INTERNAL_ERROR] = true,
    [Module.SERVICE_RESTART] = true,
    [Module.TRY_AGAIN_LATER] = true,
    [1014] = true,
}

--- Годится ли код для кадра закрытия — нашего или пришедшего.
---@param code integer
---@return boolean
function Module.sendable(code)
    if code >= OWN_FIRST then
        return code <= OWN_LAST
    end

    return REGISTERED[code] == true
end

return Module
