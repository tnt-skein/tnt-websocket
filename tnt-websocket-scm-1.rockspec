rockspec_format = '3.0'

package = 'tnt-websocket'
version = 'scm-1'

source = {
    url = 'git+https://github.com/tnt-skein/tnt-websocket.git',
    branch = 'main',
}

description = {
    summary = 'WebSocket по RFC 6455: сервер на маршруте tnt-router и клиент ws:// и wss://',
    detailed = [[
        Готового WebSocket у Tarantool нет ни в ядре, ни среди официальных
        роков, а http.server соединение из рук не выпускает: после ответа
        он ждёт на нём следующий запрос HTTP. Пакет даёт сервер на маршруте
        роутера tnt-router и клиент ws:// и wss://.

        Рукопожатие — обычный запрос по договору роутера: маршрут,
        параметры пути, слои входа, журнал, вход по куке и отказ по
        договору границы HTTP. Согласие — ответ 101 с полем takeover,
        после которого роутер отдаёт соединение сессии. Проверяются
        Origin страницы (защита от чужих страниц с кукой оператора),
        подпротокол и предел сессий маршрута. Конечная точка помнит свои
        сессии и закрывает их разом, скажем кодом 1001 перед остановкой
        сервера.

        Кадры — строго по RFC 6455: маска, длины, управляющие кадры,
        сборка сообщений из частей, UTF-8 текста, коды закрытия; каждое
        нарушение — разрыв с кодом, а не догадка. Кадры читает отдельный
        файбер: он отвечает на ping, ведёт закрытие и держит keepalive,
        а запись идёт под замком. Предел сообщения держит заявленные
        гигабайты вне памяти узла.

        Клиент — ws:// и wss:// через tnt-tls с проверкой сертификата,
        одним сроком на соединение, TLS и рукопожатие. Отказ — пара
        nil, err с родом; негодный аргумент — бросок на строке
        вызывающего.

        Сжатие сообщений permessage-deflate (RFC 7692) включается
        настройкой compress с обеих сторон: договор в рукопожатии, свой
        словарь сжатия от сообщения к сообщению, разжатие с пределом
        сообщения против «бомбы».

        Зависит от tnt-must (проверки аргументов), tnt-clock (сроки),
        tnt-context (сессия в контексте запроса), tnt-hash (SHA-1 ответа
        на ключ), tnt-log (журнал), tnt-external (подмена внешних средств
        в проверках), tnt-tls (клиент wss://) и tnt-compress (сжатие
        сообщений). Покрытие строк и убитых мутантов — 100 %.
    ]],
    homepage = 'https://github.com/tnt-skein/tnt-websocket',
    issues_url = 'https://github.com/tnt-skein/tnt-websocket/issues',
    maintainer = 'tnt-skein',
    license = 'MIT',
    labels = { 'tarantool', 'websocket', 'rfc6455', 'realtime', 'http' },
}

dependencies = {
    'lua >= 5.1',
    -- Проверки аргументов и настроек на строке вызывающего.
    'tnt-must',
    -- Сроки клиента и ожидания ответа на закрытие: миг по настоящим
    -- часам, остаток — от времени планировщика.
    'tnt-clock',
    -- Сессия идёт в контексте запроса рукопожатия: записи журнала из неё
    -- несут его опознаватель.
    'tnt-context',
    -- SHA-1 ответа на ключ клиента.
    'tnt-hash',
    -- Записи о нарушении протокола и об упавшей сессии.
    'tnt-log',
    -- Подмена сети, шифрования, случайности и часов в проверках.
    'tnt-external',
    -- Клиент wss://.
    'tnt-tls',
    -- Сжатие и разжатие сообщений permessage-deflate: DEFLATE без обёртки
    -- на системной zlib.
    'tnt-compress',
}

build = {
    type = 'builtin',
    modules = {
        ['tnt.websocket'] = 'tnt/websocket.lua',
        ['tnt.websocket.client'] = 'tnt/websocket/client.lua',
        ['tnt.websocket.codes'] = 'tnt/websocket/codes.lua',
        ['tnt.websocket.connection'] = 'tnt/websocket/connection.lua',
        ['tnt.websocket.deflate'] = 'tnt/websocket/deflate.lua',
        ['tnt.websocket.failure'] = 'tnt/websocket/failure.lua',
        ['tnt.websocket.frame'] = 'tnt/websocket/frame.lua',
        ['tnt.websocket.handshake'] = 'tnt/websocket/handshake.lua',
        ['tnt.websocket.server'] = 'tnt/websocket/server.lua',
        ['tnt.websocket.settings'] = 'tnt/websocket/settings.lua',
        ['tnt.websocket.wire'] = 'tnt/websocket/wire.lua',
    },
}
