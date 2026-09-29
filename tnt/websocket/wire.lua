--- Сокет в том виде, в каком его читает и пишет соединение WebSocket.
---
--- Соединение читает кадры `read(size, timeout)` и пишет
--- `write(data, timeout)` с ответом `true` либо `false, err`. Так уже
--- устроено соединение `tnt-tls`; обычный сокет и `sslsocket` сервера
--- отвечают на запись числом байт либо `nil` с ошибкой в самом сокете —
--- к общему виду их приводит эта обёртка.
---
--- Чтение не прячется под `pcall` нарочно: отмена файбера читателя —
--- способ остановить его, и проглоченная здесь, она не дошла бы до цикла.

local Module = {}

---@class TntWebsocketWire
---@field read fun(self: TntWebsocketWire, size: integer|table, timeout: number): string|nil
---@field write fun(self: TntWebsocketWire, data: string, timeout: number): boolean, string|nil
---@field close fun(self: TntWebsocketWire)

--- Обёртка обычного сокета либо `sslsocket` сервера.
---@param socket table
---@return TntWebsocketWire
function Module.of(socket)
    return {
        read = function(_, size, timeout)
            return socket:read(size, timeout)
        end,

        write = function(_, data, timeout)
            -- Под pcall: сокет, закрытый посреди записи, бросает, а не отвечает.
            local ok, written = pcall(socket.write, socket, data, timeout)

            if ok and written ~= nil then
                return true
            end

            return false, ok and tostring(socket:error()) or tostring(written)
        end,

        close = function()
            pcall(socket.close, socket)
        end,
    }
end

return Module
