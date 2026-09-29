--- Тесты настроек: умолчания, проверка и место броска.

local t = require('luatest')

local helper = dofile('test/helper.lua')

local g = t.group('tnt.websocket.settings')

local settings = helper.settings
local websocket = helper.websocket

--- Сессия, которой проверкам настроек звать не придётся.
local function idle() end

g.test_defaults_are_named_and_given_to_the_server = function()
    t.assert_equals(
        { settings.MAX_MESSAGE, settings.PING_INTERVAL, settings.SEND_TIMEOUT, settings.CLOSE_TIMEOUT },
        { 1048576, 30, 10, 5 }
    )
    t.assert_equals({ settings.BACKLOG, settings.TIMEOUT }, { 16, 10 })
    t.assert_equals(settings.server(nil), {
        max_message = 1048576,
        ping_interval = 30,
        send_timeout = 10,
        close_timeout = 5,
        backlog = 16,
        compress = false,
    })
end

g.test_given_values_win_over_defaults = function()
    local given = {
        max_message = 64,
        ping_interval = 2,
        send_timeout = 3,
        close_timeout = 4,
        backlog = 1,
        compress = true,
        protocols = { 'chat' },
        origins = { 'https://panel.example.org' },
        max_connections = 100,
    }

    t.assert_equals(settings.server(given), given)
end

g.test_client_gets_its_own_defaults = function()
    t.assert_equals(settings.client(nil), {
        max_message = 1048576,
        ping_interval = 30,
        send_timeout = 10,
        close_timeout = 5,
        backlog = 16,
        compress = false,
        headers = {},
        timeout = 10,
    })

    local given = {
        compress = true,
        protocols = { 'chat' },
        origin = 'https://panel.example.org',
        headers = { authorization = 'Bearer abc' },
        timeout = 2,
        verify = false,
        ca_file = '/etc/ca.pem',
        ca_path = '/etc/ca',
    }
    local got = settings.client(given)

    for name, value in pairs(given) do
        t.assert_equals(got[name], value, name)
    end
end

g.test_wrong_settings_blame_the_line_of_the_caller = function()
    helper.assert_blamed({
        {
            function()
                websocket.handler(idle, { max_mesage = 1 })
            end,
            'настройки WebSocket: ключа «max_mesage» нет, есть backlog, close_timeout, compress, max_connections, '
                .. 'max_message, origins, ping_interval, protocols, send_timeout',
        },
        {
            function()
                websocket.handler(idle, { ping_interval = 0 })
            end,
            'настройки WebSocket.ping_interval — число больше 0, а не 0',
        },
        {
            function()
                websocket.endpoint(idle, { ping_interval = 0 })
            end,
            'настройки WebSocket.ping_interval — число больше 0, а не 0',
        },
        {
            function()
                websocket.endpoint(idle, { max_mesage = 1 })
            end,
            'настройки WebSocket: ключа «max_mesage» нет, есть backlog, close_timeout, compress, max_connections, '
                .. 'max_message, origins, ping_interval, protocols, send_timeout',
        },
        {
            function()
                websocket.handler(idle, { max_message = 0 })
            end,
            'настройки WebSocket.max_message — число больше 0, а не 0',
        },
        {
            function()
                websocket.handler(idle, { send_timeout = -1 })
            end,
            'настройки WebSocket.send_timeout — число больше 0, а не -1',
        },
        {
            function()
                websocket.handler(idle, { close_timeout = 0 })
            end,
            'настройки WebSocket.close_timeout — число больше 0, а не 0',
        },
        {
            function()
                websocket.handler(idle, { backlog = 0 })
            end,
            'настройки WebSocket.backlog — число больше 0, а не 0',
        },
        {
            function()
                websocket.handler(idle, { max_connections = 0 })
            end,
            'настройки WebSocket.max_connections — число больше 0, а не 0',
        },
        {
            function()
                websocket.handler(idle, { protocols = { 'chat', 'a b' } })
            end,
            "настройки WebSocket.protocols[2] — строка по образцу ^[%w!#$%%&'*+%-.%^_`|~]+$, а не «a b»",
        },
        {
            function()
                websocket.connect('ws://localhost/', { timeout = 0 })
            end,
            'настройки клиента WebSocket.timeout — число больше 0, а не 0',
        },
        {
            function()
                websocket.connect('ws://localhost/', { protocols = { '' } })
            end,
            "настройки клиента WebSocket.protocols[1] — строка по образцу ^[%w!#$%%&'*+%-.%^_`|~]+$, а не «»",
        },
        {
            function()
                websocket.connect('ws://localhost/', { headers = { ['x-token'] = 'a\r\nHost: evil' } })
            end,
            'настройки клиента WebSocket.headers[x-token] — строка по образцу ^[^\r\n]*$, а не «a\r\nHost: evil»',
        },
        {
            function()
                websocket.connect('ws://localhost/', { headers = { ['bad name'] = 'a' } })
            end,
            'настройки клиента WebSocket.headers[bad name] — строка по образцу '
                .. "^[%w!#$%%&'*+%-.%^_`|~]+$, а не «bad name»",
        },
    })
end

g.after_each(function()
    helper.restore()
end)

--- Подменяет сжатию загрузчик библиотеки: узел без zlib.
local function without_zlib()
    helper.compress._set_source({
        load = function(name)
            error(('нет %s'):format(name), 0)
        end,
    })
end

g.test_compression_without_zlib_blames_the_line_of_the_caller = function()
    without_zlib()

    helper.assert_blamed({
        {
            function()
                websocket.handler(idle, { compress = true })
            end,
            'настройки WebSocket.compress: нет системной библиотеки zlib: нет z; нет libz.so.1',
        },
        {
            function()
                websocket.connect('ws://localhost/', { compress = true })
            end,
            'настройки клиента WebSocket.compress: нет системной библиотеки zlib: нет z; нет libz.so.1',
        },
        {
            function()
                websocket.handler(idle, { compress = 'yes' })
            end,
            'настройки WebSocket.compress — логическое значение, а не строка',
        },
    })
end

g.test_node_without_zlib_serves_without_compression = function()
    without_zlib()

    t.assert_equals(type(websocket.handler(idle)), 'function')
    t.assert_equals(settings.client(nil).compress, false)
end
