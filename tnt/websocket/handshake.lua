--- Рукопожатие WebSocket: общее для сервера и клиента (RFC 6455, §4).
---
--- Рукопожатие — обычный запрос HTTP с просьбой сменить протокол
--- и ответ 101 на него. Сервер доказывает, что понял просьбу, ответом
--- на ключ клиента: base64 от SHA-1 ключа, склеенного с GUID из RFC.
--- Иначе ответ кэша или прокси, не знающих WebSocket, клиент принял бы
--- за согласие.

local hash = require('tnt.hash')

local Module = {}

--- Строка, которую RFC 6455 клеит к ключу клиента (§1.3).
Module.GUID = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11'

--- Версия протокола — единственная, о которой договариваются.
Module.VERSION = '13'

--- Ключ клиента — 16 байт в base64: 22 знака, последний несёт только
--- два старших бита (A, Q, g, w), и два знака набивки.
---
--- Строгий образец, а не «что-то из base64»: ключ, у которого иная
--- длина, — не рукопожатие RFC 6455, и отвечать на него 101 нельзя (§4.2.1).
Module.KEY = '^' .. string.rep('[%w+/]', 21) .. '[AQgw]==$'

--- Имя подпротокола — «лексема» HTTP: видимые знаки без разделителей.
Module.TOKEN = "^[%w!#$%%&'*+%-.%^_`|~]+$"

--- Ответ сервера на ключ клиента (§4.2.2).
---@param key string Ключ из `Sec-WebSocket-Key`
---@return string
function Module.accept_of(key)
    return hash.digest('sha1', key .. Module.GUID, 'base64')
end

--- Значения заголовка-списка: через запятую, без пробелов по краям.
---@param value string|nil
---@return string[]
function Module.listed(value)
    local items = {}

    -- `split`, а не обход образцом `[^,]+`: мутант повтора `[^,]*` дал бы
    -- только пустые куски, которые отсекаются так же, и был бы неотличим.
    for _, part in ipairs(tostring(value or ''):split(',')) do
        local item = part:match('^%s*(.-)%s*$')

        if item ~= '' then
            table.insert(items, item)
        end
    end

    return items
end

--- Есть ли в заголовке-списке слово — без оглядки на регистр.
---
--- `Connection: keep-alive, Upgrade` шлёт Firefox, и сравнение всей
--- строки с `upgrade` ему отказало бы.
---@param value string|nil
---@param word string Слово в нижнем регистре
---@return boolean
function Module.names(value, word)
    for _, item in ipairs(Module.listed(value)) do
        if item:lower() == word then
            return true
        end
    end

    return false
end

return Module
