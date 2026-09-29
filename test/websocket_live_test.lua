--- Живая сверка сервера с чужой реализацией: клиент WebSocket из Node.
---
--- Свои клиент и сервер могли бы сойтись друг с другом и в общей ошибке.
--- В Node с 22-й версии встроен клиент `WebSocket` (undici) — тот же, что
--- у браузеров по договору WHATWG: маска, части, ping и закрытие у него
--- свои. Он же всегда предлагает `permessage-deflate` и разжимает сжатое
--- сервером своей zlib, держа словарь от сообщения к сообщению. Без Node
--- или без встроенного клиента проверка пропускается.

local t = require('luatest')

local http_server = require('http.server')
local json = require('json')
local popen = require('popen')

local helper = dofile('test/helper.lua')

local g = t.group('tnt.websocket.live')

local websocket = helper.websocket

--- Сценарий клиента: два сообщения, большое, ответы, закрытие своим кодом.
local SCRIPT = [[
const ws = new WebSocket(process.argv[1], ['echo.v1']);
ws.binaryType = 'arraybuffer';
const got = [];
const big = 'ж'.repeat(70000);
ws.onopen = () => {
    ws.send('привет');
    ws.send(new Uint8Array([0, 255, 1]));
    ws.send(big);
};
ws.onmessage = (event) => {
    got.push(typeof event.data === 'string'
        ? (event.data === big ? 'big' : event.data)
        : Array.from(new Uint8Array(event.data)));
    if (got.length === 3) ws.close(4001, 'пока');
};
ws.onclose = (event) => {
    const { code, reason, wasClean: clean } = event;
    const { protocol, extensions } = ws;
    console.log(JSON.stringify({ protocol, extensions, got, code, reason, clean }));
};
]]

--- Выполняет команду и отдаёт её вывод, не останавливая узел.
---
--- `popen` программу по `PATH` не ищет — её ищет `env`.
---@param argv string[]
---@return string output
---@return integer|nil status Код выхода
local function run(argv)
    local command = { '/usr/bin/env' }

    for _, arg in ipairs(argv) do
        table.insert(command, arg)
    end

    local ok, handle = pcall(popen.new, command, { stdout = popen.opts.PIPE, stderr = popen.opts.DEVNULL })

    if not ok or handle == nil then
        return '', nil
    end

    local parts = {}

    while true do
        local part = handle:read({ timeout = 10 })

        if part == nil or part == '' then
            break
        end

        table.insert(parts, part)
    end

    local status = handle:wait()

    handle:close()

    return table.concat(parts), status.exit_code
end

--- Есть ли Node со встроенным клиентом WebSocket.
---@return boolean
local function node_ready()
    local _, status = run({ 'node', '-e', "process.exit(typeof WebSocket === 'function' ? 0 : 1)" })

    return status == 0
end

g.before_all(function()
    g.ready = node_ready()
end)

--- Разговор клиента Node с сервером пакета по сценарию.
---@param opts table|nil Настройки сервера поверх общих
---@return table output Что клиент вывел по закрытии
---@return table|nil ended Чем кончилась сессия у сервера
local function talked(opts)
    local router = helper.load_router()
    local httpd = http_server.new('127.0.0.1', 0, { log_requests = false, log_errors = false, idle_timeout = 5 })
    local ended

    router.get(
        '/echo',
        websocket.handler(function(ws)
            while true do
                local message, err = ws:receive()

                if message == nil then
                    ended = { code = err.code, reason = err.reason }

                    return
                end

                ws:send(message.data, message.kind)
            end
        end, {
            protocols = { 'echo.v1' },
            max_message = 256 * 1024,
            ping_interval = 0.2,
            compress = (opts or {}).compress,
        })
    )

    router.attach(httpd)
    httpd:start()

    local url = ('ws://127.0.0.1:%d/echo'):format(httpd.tcp_server:name().port)
    local output = run({ 'node', '-e', SCRIPT, url })

    httpd:stop()
    helper.unload_router()

    return json.decode(output), ended
end

g.test_node_client_talks_to_the_server_and_closes_cleanly = function()
    t.skip_if(not g.ready, 'нет Node со встроенным клиентом WebSocket')

    local output, ended = talked()

    -- Клиент видит код и причину нашего ответного кадра: ответ — эхо кода
    -- без причины (RFC 6455, §5.5.1), поэтому причина у него пустая.
    t.assert_equals(output, {
        protocol = 'echo.v1',
        extensions = '',
        got = { 'привет', { 0, 255, 1 }, 'big' },
        code = 4001,
        reason = '',
        clean = true,
    })
    t.assert_equals(ended, { code = 4001, reason = 'пока' })
end

g.test_node_client_reads_what_the_server_compressed = function()
    t.skip_if(not g.ready, 'нет Node со встроенным клиентом WebSocket')

    local output, ended = talked({ compress = true })

    -- Три сжатых ответа одним словарём: большой текст ссылается на уже
    -- ушедшее, и клиент разжимает его своей zlib.
    t.assert_equals(output, {
        protocol = 'echo.v1',
        extensions = 'permessage-deflate; client_no_context_takeover',
        got = { 'привет', { 0, 255, 1 }, 'big' },
        code = 4001,
        reason = '',
        clean = true,
    })
    t.assert_equals(ended, { code = 4001, reason = 'пока' })
end
