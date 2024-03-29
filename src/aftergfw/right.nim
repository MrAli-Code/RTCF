import chronos, chronos/transports/ipnet, chronos/osdefs
import adapters/[ws, mux], tunnel
import store, shared, httputils
import websock/[websock, extensions/compression/deflate]

from globals import nil

logScope:
    topic = "Kharej RightSide"


const parallelCons = 4

var disconnectEV = newAsyncEvent()
var activeCons = 0

proc connect(): Future[WSSession] {.async.} =
    {.cast(raises: []), gcsafe.}:
        try:
            let foctories = case globals.compressor:
            of deflate:
                @[deflateFactory()]
            else:
                @[]
            let ws = when true:
                await WebSocket.connect(
                    globals.cdn_domain & ":" & $globals.iran_port,
                    hostname = globals.cdn_domain,
                    path = "/ws" & $globals.sh1,
                    secure = true,
                    factories = foctories,
                    flags = {})
                else:
                    await WebSocket.connect(
                        initTAddress(globals.cdn_domain, globals.iran_port),
                        path = "/ws" & $globals.sh1,
                        factories = [deflateFactory])

            return ws
        except [WebSocketError, HttpError]:
            var e = getCurrentException()
            error "Websocket error", name = e.name, msg = e.msg
            raise e


proc standAloneChain(){.async.} =
    trace "Initiating connection"
    {.cast(raises: []), gcsafe.}:
        try:
            var timeout = sleepAsync(2.seconds)
            var wsf = connect()
            if (await race(wsf, timeout)) == timeout:
                wsf.cancelSoon()
                wsf.addCallback(proc (udata:pointer) =
                    if wsf.finished() and not wsf.failed():
                        if wsf.value() != nil:
                            wsf.value().stream.close()
                )

                raise newException(AsyncTimeoutError, "timeed out")
            if wsf.failed(): raise wsf.error()
            let ws = wsf.value()
            var mux_adapter = newMuxAdapetr(master = masterChannel, store = publicStore, loc = AfterGfw)
            var ws_adapter = newWebsocketAdapter(socket = ws, store = publicStore,
            onClose = proc() =
                {.cast(raises: []), gcsafe.}:
                    dec activeCons; disconnectEV.fire())
            mux_adapter.chain(ws_adapter)
            mux_adapter.signal(both, start)
            info "Connected to the target!"
            inc activeCons

        except:
            # print getCurrentException()
            {.cast(raises: []), gcsafe.}: disconnectEV.fire()



proc logs(){.async.} =
    while true:
        echo "right"
        await sleepAsync(1.seconds)


proc reconnect(){.async.} =
    {.cast(raises: []), gcsafe.}:
        var gfs{.global.} = false
        while true:
            await disconnectEV.wait()
            if gfs:
                info "Reconnecting in 3 secconds..."
                await sleepAsync(3.seconds)
            else:
                gfs = true
            disconnectEV.clear()
            for i in activeCons..<parallelCons:
                await standAloneChain()


proc run*(thread: int) {.async.} =
    await sleepAsync(200.milliseconds)
    {.cast(raises: []), gcsafe.}: disconnectEV.clear()
    asyncSpawn reconnect()
    # asyncSpawn standAloneChain()
    #     info "Mode Kharej"
    # asyncSpawn logs()

    dynamicLogScope(thread):
        {.cast(raises: []), gcsafe.}: disconnectEV.fire()



