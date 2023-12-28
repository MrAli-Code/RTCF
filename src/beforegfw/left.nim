import chronos, chronos/transports/[datagram, ipnet], chronos/osdefs
import adapters/[ws, connection, mux]
import tunnel, tunnels/[port, tcp, udp, transportident]
import store, shared
from globals import nil

logScope:
    topic = "Iran LeftSide"


proc startTcpListener(threadID: int) {.async.} =
    {.cast(gcsafe).}:
        var foundpeer = false
        proc serveStreamClient(server: StreamServer,
                        transp: StreamTransport) {.async.} =
            try:
                if not foundpeer:
                    when helpers.hasThreadSupport:
                        lock(peerConnectedlock):
                            foundpeer = peerConnected
                    else:
                        foundpeer = peerConnected
                if not foundpeer:
                    error "user connection but no foreign server connected yet!, closing..."
                    transp.close();return

                let address = transp.remoteAddress()
                trace "Got connection", form = address
                block spawn:
                    var con_adapter = newConnectionAdapter(socket = transp, store = publicStore)
                    var port_tunnel = newPortTunnel(multiport = globals.multi_port, writeport = globals.listen_port)
                    var tcp_tunnel = newTcpTunnel(store = publicStore, fakeupload_ratio = 0)
                    var mux_adapter = newMuxAdapetr(master = masterChannel, store = publicStore, loc = BeforeGfw)
                    con_adapter.chain(port_tunnel).chain(tcp_tunnel).chain(mux_adapter)
                    con_adapter.signal(both, start)

            except CatchableError as e:
                error "handle client connection error", name = e.name, msg = e.msg


        var address = initTAddress(globals.listen_addr, globals.listen_port.Port)
        let server: StreamServer =
            try:
                var flags = {ServerFlags.TcpNoDelay, ServerFlags.ReuseAddr, ServerFlags.ReusePort}
                if globals.keep_system_limit:
                    flags.excl ServerFlags.TcpNoDelay
                createStreamServer(address, serveStreamClient, flags = flags)
            except CatchableError as e:
                fatal "StreamServer creation failed", name = e.name, msg = e.msg
                quit(1)

        server.start()
        info "Started tcp server", listen = globals.listen_addr, port = globals.listen_port
        await server.join()



proc run*(thread: int) {.async.} =
    await sleepAsync(200)
    # if globals.accept_udp:
    #     info "Mode Iran (Tcp + Udp)"
    # else:
    #     info "Mode Iran"
    dynamicLogScope(thread):
        await startTcpListener(thread)

