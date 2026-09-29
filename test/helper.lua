--- Общие средства проверок WebSocket.
---
--- Соединение проверяется на настоящей паре сокетов (`socket.socketpair`):
--- сроки, конец потока, запись в полный буфер и отмена файбера держатся
--- на ядре, и подделка сокета тут доказала бы только, что мы правильно
--- разговариваем сами с собой. Та сторона пары — «собеседник»: проверка
--- пишет в него кадры руками и читает, что прислало соединение.
---
--- Кадры собеседника собираются тем же `frame.encode`, а байты самого
--- `encode` сверяются с примерами RFC 6455 (§5.7) в `frame_test.lua`, так что
--- по кругу это не замыкается. Поведение с чужой реализацией — браузером
--- и клиентом другого языка — проверяется живьём, `websocket_live_test.lua`.
---
--- Исходники читаются с диска, а не через `require`: у Tarantool свой
--- загрузчик `.rocks`, он идёт раньше `package.path` и подсунул бы
--- установленную копию пакета, если она есть. Проверки тогда шли бы
--- против вчерашнего кода, а покрытие считалось бы по нему. Зависимости
--- пакета — `tnt-must`, `tnt-clock`, `tnt-context`, `tnt-hash`, `tnt-log`,
--- `tnt-external`, `tnt-tls` и `tnt-compress` — берутся из `.rocks` обычным
--- `require`: проверяется этот пакет, а не они.
---
--- Сжатие `tnt-compress` из `.rocks` одно на процесс, и его подмена
--- системной zlib пережила бы проверку, которая её поставила: следующие
--- файлы проверок сжимали бы подменой. Поэтому `restore` снимает её сама
--- (`_set_source(nil)`), вместе с подменами пакета.
---
--- Роутер `tnt-router` стоит в `.rocks` (`make deps`) и зависимостью
--- пакета не объявлен: он нужен только проверкам стыка, где рукопожатие
--- идёт настоящим маршрутом, а соединение забирает его `takeover`.
---
--- Оснастка в `test/testing/` — загрузчик исходников, часы с работой без
--- уступки и ловушка журнала — грузится так же, файлами, и один раз
--- на процесс: второй экземпляр загрузчика не знал бы, что вытеснил
--- первый, и не вернул бы вытесненное на место.
---
--- Проверки берут всё через этот помощник, а не из оснастки напрямую:
--- помощник — единственное, чем файл проверок отличается от того же файла
--- в наборе, где пакет живёт рядом со своими зависимостями.

-- luatest сам берёт этот файл — `require('test.helper')` — раньше, чем
-- включает замер покрытия. Исходники, прочитанные тогда, прошли бы мимо
-- замера, и то, что модуль делает один раз на процесс, в загрузках из
-- файлов проверок уже не исполнилось бы: покрытие сочло бы эти строки
-- пропущенными. Помощник нужен только файлам проверок, которые берут его
-- `dofile` (без имени модуля), и на эту загрузку он ничего не делает.
if ... == 'test.helper' then
    return {}
end

local fio = require('fio')
local socket = require('socket')
local t = require('luatest')

--- Модули оснастки в порядке зависимостей: ловушка журнала берёт загрузчик.
local TESTING = {
    { name = 'tnt.testing.sources', path = 'test/testing/sources.lua' },
    { name = 'tnt.testing.clock', path = 'test/testing/clock.lua' },
    { name = 'tnt.testing.journal', path = 'test/testing/journal.lua' },
}

for _, module in ipairs(TESTING) do
    if package.loaded[module.name] == nil then
        local chunk, failure = loadfile(fio.abspath(module.path))

        if chunk == nil then
            error(('оснастка %s не читается: %s'):format(module.name, tostring(failure)))
        end

        package.loaded[module.name] = chunk()
    end
end

--- Оснастка проверок под теми именами, что зовёт помощник.
local testing = {
    load_sources = package.loaded['tnt.testing.sources'].load,
    module = package.loaded['tnt.testing.sources'].module,
    capture_log = package.loaded['tnt.testing.journal'].capture,
    work_without_yielding = package.loaded['tnt.testing.clock'].work_without_yielding,
}

local helper = {
    --- Модули пакета в порядке зависимостей: имя и путь исходника.
    MODULES = {
        { name = 'tnt.websocket.codes', path = 'tnt/websocket/codes.lua' },
        { name = 'tnt.websocket.failure', path = 'tnt/websocket/failure.lua' },
        { name = 'tnt.websocket.frame', path = 'tnt/websocket/frame.lua' },
        { name = 'tnt.websocket.wire', path = 'tnt/websocket/wire.lua' },
        { name = 'tnt.websocket.handshake', path = 'tnt/websocket/handshake.lua' },
        { name = 'tnt.websocket.deflate', path = 'tnt/websocket/deflate.lua' },
        { name = 'tnt.websocket.settings', path = 'tnt/websocket/settings.lua' },
        { name = 'tnt.websocket.connection', path = 'tnt/websocket/connection.lua' },
        { name = 'tnt.websocket.server', path = 'tnt/websocket/server.lua' },
        { name = 'tnt.websocket.client', path = 'tnt/websocket/client.lua' },
        { name = 'tnt.websocket', path = 'tnt/websocket.lua' },
    },
}

--- Фасад пакета из исходников.
---
--- Грузится один раз на процесс: состояния у модулей нет, кроме внешних зависимостей,
--- а внешние зависимости проверки возвращают сами (`restore`).
helper.websocket = testing.load_sources(helper.MODULES, 'tnt.websocket')

--- Части пакета из той же загрузки, что и фасад.
helper.codes = testing.module('tnt.websocket.codes')
helper.failure = testing.module('tnt.websocket.failure')
helper.frame = testing.module('tnt.websocket.frame')
helper.wire = testing.module('tnt.websocket.wire')
helper.handshake = testing.module('tnt.websocket.handshake')
helper.deflate = testing.module('tnt.websocket.deflate')
helper.settings = testing.module('tnt.websocket.settings')
helper.connection = testing.module('tnt.websocket.connection')
helper.server = testing.module('tnt.websocket.server')
helper.client = testing.module('tnt.websocket.client')
helper.context = require('tnt.context')
helper.compress = require('tnt.compress')

--- Значение мимо проверки типов: негодный аргумент нарочно.
---@param value any
---@return any
function helper.wrong(value)
    return value
end

--- Сверяет, что каждый вызов бросает названный отказ и винит строку
--- вызова в файле проверок, а не внутри пакета.
---
--- Вызов стоит в замыкании первой строкой тела, то есть строкой ниже
--- слова `function`: место броска сверяется с ней целиком — файлом,
--- строкой и текстом.
---@param cases table[] Пары: замыкание с вызовом и текст броска
function helper.assert_blamed(cases)
    for _, case in ipairs(cases) do
        local _, err = pcall(case[1])
        local info = debug.getinfo(case[1], 'S') --[[@as { short_src: string, linedefined: integer }]]

        t.assert_equals(err, ('%s:%d: %s'):format(info.short_src, info.linedefined + 1, case[2]))
    end
end

--- Ловушка журнала: записи `tnt-log` на время проверки.
helper.capture_log = testing.capture_log

--- Работа без уступки управления: отметка цикла событий отстаёт от
--- настоящих часов ровно на её время.
helper.work_without_yielding = testing.work_without_yielding

--- Роутер для проверок стыка — свежий, без чужих маршрутов: `takeover`
--- держит он, а отказ рукопожатия рисует его обработчик отказов.
---
--- Роутер один на процесс, из `.rocks`, и маршруты общего роутера
--- пережили бы проверку: оставленный соседней проверкой маршрут сделал
--- бы их порядок частью смысла. Поэтому проверке достаётся отдельный
--- роутер (`new`) — с тем же договором, что у общего, и без его маршрутов.
---@return table router
function helper.load_router()
    return require('tnt.router').new()
end

--- Отдельный роутер уходит вместе с проверкой, и выгружать нечего.
function helper.unload_router() end

--- Ключ маски собеседника: байты разные, чтобы сдвиг ключа был виден.
helper.KEY = '\x37\xfa\x21\x3d'

--- Ключ рукопожатия из примера RFC 6455 (§1.3) и ответ на него.
helper.SAMPLE_KEY = 'dGhlIHNhbXBsZSBub25jZQ=='
helper.SAMPLE_ACCEPT = 's3pPLMBiTxaQ9kYGzzhZRbK+xOo='

--- Возвращает пакету и сжатию настоящие средства.
function helper.restore()
    helper.connection._set_source(nil)
    helper.client._set_source(nil)
    helper.compress._set_source(nil)
end

--- Настройки соединения для проверок: короткие сроки поверх умолчаний.
---@param overrides table|nil
---@return table
function helper.settings_of(overrides)
    local settings = {
        max_message = 1024,
        ping_interval = 5,
        send_timeout = 1,
        close_timeout = 1,
        backlog = 4,
    }

    for name, value in pairs(overrides or {}) do
        settings[name] = value
    end

    return settings
end

---@class TntWebsocketPair
---@field connection any Соединение пакета: поля отказа проверки читают без сужения
---@field peer table Сокет собеседника
---@field wire TntWebsocketWire Тот же сокет обёрткой пакета
---@field own table Сокет соединения пакета

--- Соединение пакета на одном конце пары сокетов, собеседник — на другом.
---
--- По умолчанию соединение — сервер: ждёт кадров с маской и шлёт без неё.
---@param overrides table|nil Настройки поверх коротких сроков
---@param client boolean|nil Соединение — клиент: маскирует и владеет сокетом
---@param deflate TntWebsocketDeflate|nil Договор о сжатии; без него — несжатые
---@return TntWebsocketPair
function helper.pair(overrides, client, deflate)
    local own, peer = socket.socketpair('AF_UNIX', 'SOCK_STREAM', 0)

    local connection = helper.connection.new(helper.wire.of(own), {
        masking = client == true,
        owned = client == true,
        settings = helper.settings_of(overrides),
        protocol = 'chat',
        request = { path = '/ws' },
        deflate = deflate,
    })

    return { connection = connection, peer = peer, wire = helper.wire.of(peer), own = own }
end

--- Кадр от собеседника-клиента: с маской.
---@param opcode integer
---@param payload string
---@param fin boolean|nil Последний ли кадр; по умолчанию да
---@param compressed boolean|nil Поднять ли RSV1
---@return string
function helper.masked(opcode, payload, fin, compressed)
    local bytes = helper.frame.encode(opcode, payload, helper.KEY, compressed)

    if fin == false then
        return string.char((bytes:byte(1) - 0x80) --[[@as integer]]) .. bytes:sub(2)
    end

    return bytes
end

--- Кадр от собеседника-сервера: без маски.
---@param opcode integer
---@param payload string
---@param fin boolean|nil
---@param compressed boolean|nil Поднять ли RSV1
---@return string
function helper.plain(opcode, payload, fin, compressed)
    local bytes = helper.frame.encode(opcode, payload, nil, compressed)

    if fin == false then
        return string.char((bytes:byte(1) - 0x80) --[[@as integer]]) .. bytes:sub(2)
    end

    return bytes
end

--- Сколько секунд собеседник ждёт кадра, если проверка не сказала иного.
---
--- Короткому кадру этого хватает с запасом. Длинное сообщение пишется,
--- пока собеседник его читает, и под нагрузкой полного прогона идёт
--- дольше: проверка такого сообщения ждёт кадр своим сроком записи.
helper.HEARD_WITHIN = 2

--- Кадр, который прислало соединение, — глазами собеседника.
---@param pair TntWebsocketPair
---@param masked boolean|nil Ждать ли маску: соединение — клиент
---@param seconds number|nil Сколько ждать начала кадра и каждой его части
---@return any frame Кадр; nil — если его нет
---@return table|nil trouble
function helper.heard(pair, masked, seconds)
    local within = seconds or helper.HEARD_WITHIN

    return helper.frame.read(
        pair.wire,
        { masked = masked == true, deflate = true, room = 16 * 1024 * 1024, idle = within, timeout = within }
    )
end

--- Ждёт, пока соединение закроется, но не дольше срока.
---@param connection TntWebsocketConnection
---@param seconds number|nil
function helper.settled(connection, seconds)
    local deadline = require('clock').monotonic() + (seconds or 3)

    while connection.state ~= 'closed' and require('clock').monotonic() < deadline do
        require('fiber').sleep(0.01)
    end
end

return helper
