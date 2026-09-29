--- Настройки WebSocket: проверка и умолчания.
---
--- Негодная настройка — ошибка программиста и бросок там, где её дали:
--- при объявлении маршрута (`handler`) и при `connect`, а не на первом
--- кадре посреди разговора. Бросок показывает на строку вызывающего
--- фасада: проверку зовёт фасад, поэтому уровень вины на кадр глубже.
---
--- Сжатие (`compress`) по умолчанию выключено: словарь сжатия держит
--- память zlib на каждое соединение, а сжатие и разжатие идут счётом
--- в потоке событий узла. Включает его тот, у кого сообщения большие
--- и похожие друг на друга — JSON снимков, журналы, — а канал узкий.

local compress = require('tnt.compress')
local must = require('tnt.must')

local handshake = require('tnt.websocket.handshake')

local Module = {}

--- Сколько байт в сообщении принять по умолчанию.
---
--- Мегабайт — с запасом для команд и снимков состояния, но сообщение
--- собирается в памяти целиком, и сотня соединений с гигабайтными
--- сообщениями положила бы узел раньше, чем кто-то заметил.
Module.MAX_MESSAGE = 1024 * 1024

--- Сколько секунд молчания до ping. Прокси по дороге (nginx) рвут
--- простаивающее соединение через минуту — ping раньше держит его живым.
Module.PING_INTERVAL = 30

--- Сколько секунд ждать очереди записи и самой записи кадра.
Module.SEND_TIMEOUT = 10

--- Сколько секунд ждать ответа на своё закрытие.
Module.CLOSE_TIMEOUT = 5

--- Сколько непрочитанных сообщений держит ящик, прежде чем читатель встанет.
Module.BACKLOG = 16

--- Сколько секунд даётся клиенту на соединение, TLS и рукопожатие вместе.
Module.TIMEOUT = 10

--- Уровень вины: строка того, кто позвал фасад.
local owner = must.at(3)

--- Тот же уровень для помощников, которых зовут `server` и `client`.
local nested = must.at(4)

--- Настройки соединения — общие для сервера и клиента.
local CONNECTION = {
    max_message = '?integer',
    ping_interval = '?number',
    send_timeout = '?number',
    close_timeout = '?number',
    backlog = '?integer',
    compress = '?boolean',
}

--- Настройки, которые есть только у сервера.
local SERVER = {
    protocols = { '?array_of', 'string' },
    origins = { '?array_of', 'not_empty' },
    max_connections = '?integer',
}

--- Настройки, которые есть только у клиента.
local CLIENT = {
    protocols = { '?array_of', 'string' },
    origin = '?not_empty',
    headers = '?table',
    timeout = '?number',
    verify = '?boolean',
    ca_file = '?not_empty',
    ca_path = '?not_empty',
}

--- Описание настроек: общие и свои.
---@param own table
---@return table
local function described(own)
    local shape = table.copy(CONNECTION)

    for name, rule in pairs(own) do
        shape[name] = rule
    end

    return shape
end

--- Проверенные общие настройки с умолчаниями.
---@param opts table
---@param title string
---@return TntWebsocketSettings
local function connection_of(opts, title)
    local settings = {
        max_message = opts.max_message or Module.MAX_MESSAGE,
        ping_interval = opts.ping_interval or Module.PING_INTERVAL,
        send_timeout = opts.send_timeout or Module.SEND_TIMEOUT,
        close_timeout = opts.close_timeout or Module.CLOSE_TIMEOUT,
        backlog = opts.backlog or Module.BACKLOG,
        compress = opts.compress or false,
    }

    for _, name in ipairs({ 'max_message', 'ping_interval', 'send_timeout', 'close_timeout', 'backlog' }) do
        nested.positive(settings[name], ('%s.%s'):format(title, name))
    end

    -- Узел без zlib узнаёт об этом, объявляя маршрут или соединяясь,
    -- а не на первом сжатом сообщении посреди разговора.
    if settings.compress then
        local ready, why = compress.available()

        if not ready then
            error(('%s.compress: %s'):format(title, why), 4)
        end
    end

    return settings
end

--- Подпротоколы: лексемы HTTP, иначе заголовок их не пронесёт.
---@param protocols string[]|nil
---@param title string
local function tokens(protocols, title)
    if protocols ~= nil then
        nested.all.matches(protocols, title .. '.protocols', handshake.TOKEN)
    end
end

---@class TntWebsocketServerSettings: TntWebsocketSettings
---@field protocols string[]|nil Подпротоколы в порядке предпочтения
---@field origins string[]|nil Разрешённые источники страниц
---@field max_connections integer|nil Предел сессий обработчика

---@class TntWebsocketClientSettings: TntWebsocketSettings
---@field protocols string[]|nil Подпротоколы, которые предложить
---@field origin string|nil Заголовок Origin
---@field headers table<string, string> Свои заголовки рукопожатия
---@field timeout number Срок на соединение, TLS и рукопожатие
---@field verify boolean|nil Проверять ли сертификат
---@field ca_file string|nil
---@field ca_path string|nil

--- Настройки стороны сервера: общие, подпротоколы, источники и предел.
---@param opts table|nil
---@return TntWebsocketServerSettings
function Module.server(opts)
    local given = opts or {}
    local title = 'настройки WebSocket'

    owner.options(given, title, described(SERVER))
    tokens(given.protocols, title)
    owner.optional.positive(given.max_connections, title .. '.max_connections')

    local settings = connection_of(given, title) --[[@as TntWebsocketServerSettings]]

    settings.protocols = given.protocols
    settings.origins = given.origins
    settings.max_connections = given.max_connections

    return settings
end

--- Настройки клиента: общие, подпротоколы, заголовки, срок и TLS.
---
--- Значение заголовка с переводом строки — бросок: оно дописало бы
--- в рукопожатие свой заголовок, а то и свой запрос.
---@param opts table|nil
---@return TntWebsocketClientSettings
function Module.client(opts)
    local given = opts or {}
    local title = 'настройки клиента WebSocket'

    owner.options(given, title, described(CLIENT))
    tokens(given.protocols, title)

    for name, value in pairs(given.headers or {}) do
        local where = ('%s.headers[%s]'):format(title, tostring(name))

        owner.matches(name, where, handshake.TOKEN)
        owner.matches(value, where, '^[^\r\n]*$')
    end

    local settings = connection_of(given, title) --[[@as TntWebsocketClientSettings]]

    settings.protocols = given.protocols
    settings.origin = given.origin
    settings.headers = given.headers or {}
    settings.timeout = given.timeout or Module.TIMEOUT
    settings.verify = given.verify
    settings.ca_file = given.ca_file
    settings.ca_path = given.ca_path
    owner.positive(settings.timeout, title .. '.timeout')

    return settings
end

return Module
