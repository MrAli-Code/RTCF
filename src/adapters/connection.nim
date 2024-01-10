import tunnel, store, timerdispatcher
import chronos/transports/stream


logScope:
    topic = "Connection Adapter"


#     1    2    3    4    5    6    7 ...
# ---------------------------------------------------
#                 User Requets
# ---------------------------------------------------
#     Connection contains variable lenght data      |
# ---------------------------------------------------


type
    ConnectionAdapter* = ref object of Adapter
        socket: StreamTransport
        readLoopFut: Future[void]
        writeLoopFut: Future[void]
        store: Store
        lastUpdate: Moment
        td: TimerDispatcher
        td_id: int64
        firstread: bool

const
    bufferSize = 4093
    timeOut = 180.seconds
    writeTimeOut = 2.seconds
    firstReadTimeout = 3.seconds

proc getRawSocket*(self: ConnectionAdapter): StreamTransport {.inline.} = self.socket
template stillAlive(){.dirty.} = self.lastUpdate = Moment.now()



# called when we are on the right side
proc readloop(self: ConnectionAdapter){.async.} =
    #read data from chain, write to socket
    var socket = self.socket
    var sv: StringView = nil
    while not self.stopped:
        stillAlive()
        try:
            sv = await procCall read(Tunnel(self), 1)
            trace "Readloop Read", bytes = sv.len
        except [CancelledError, FlowError, AsyncChannelError]:
            var e = getCurrentException()
            warn "Readloop Cancel [Read]", msg = e.name
            if not self.stopped: signal(self, both, close)
            return
        except CatchableError as e:
            error "Readloop Unexpected Error, [Read]", name = e.name, msg = e.msg
            quit(1)


        try:
            trace "Readloop write to socket", count = sv.len
            if sv.len != await socket.write(sv.buf, sv.len).wait(writeTimeOut):
                raise newAsyncStreamIncompleteError()

        except [CancelledError, FlowError, AsyncTimeoutError, TransportError, AsyncChannelError, AsyncStreamError]:
            var e = getCurrentException()
            warn "Readloop Cancel [Write]", msg = e.name
            if not self.stopped: signal(self, both, close)
            return
        except CatchableError as e:
            error "Readloop Unexpected Error, [Write]", name = e.name, msg = e.msg
            quit(1)
        finally:
            self.store.reuse move sv



proc writeloop(self: ConnectionAdapter){.async.} =
    #read data from socket, write to chain
    var socket = self.socket
    var sv: StringView = nil
    while not self.stopped:
        stillAlive()

        try:
            sv = self.store.pop()
            sv.reserve(bufferSize)

            var actual = await socket.readOnce(sv.buf(), bufferSize).wait(
                if self.firstread: self.firstread = false; firstReadTimeout else: InfiniteDuration
                )

            if actual == 0:
                trace "Writeloop read 0 !";
                self.store.reuse move sv
                if not self.stopped: signal(self, both, close)
                break
            else:
                trace "Writeloop read", bytes = actual
            sv.setLen(actual)

        except [CancelledError, TransportError, AsyncTimeoutError, AsyncChannelError]:
            var e = getCurrentException()
            trace "Writeloop Cancel [Read]", msg = e.name
            self.store.reuse sv
            if not self.stopped: signal(self, both, close)
            return
        except CatchableError as e:
            error "Writeloop Unexpected Error [Read]", name = e.name, msg = e.msg
            quit(1)



        try:
            trace "Writeloop write", bytes = sv.len
            await procCall write(Tunnel(self), move sv)

        except [CancelledError, FlowError, AsyncChannelError]:
            var e = getCurrentException()
            trace "Writeloop Cancel [Write]", msg = e.name
            if sv != nil: self.store.reuse sv
            if not self.stopped: signal(self, both, close)
            return
        except CatchableError as e:
            error "Writeloop Unexpected Error [Write]", name = e.name, msg = e.msg
            quit(1)


proc checkalive(obj:Tunnel) =
    assert obj != nil
    var self = ConnectionAdapter(obj)
    if not self.stopped:
        if self.lastUpdate + timeOut < Moment.now():
            signal(self, both, close)

proc init(self: ConnectionAdapter, name: string, socket: StreamTransport, store: Store, td: TimerDispatcher){.raises: [].} =
    procCall init(Adapter(self), name, hsize = 0)
    self.socket = socket
    self.store = store
    self.lastUpdate = Moment.now()
    self.td = td
    self.firstread = true

    self.td_id = td.register(self,checkalive)


proc newConnectionAdapter*(name: string = "ConnectionAdapter", socket: StreamTransport, store: Store, td: TimerDispatcher): ConnectionAdapter {.raises: [].} =
    result = new ConnectionAdapter
    result.init(name, socket, store, td)
    trace "Initialized", name


method write*(self: ConnectionAdapter, rp: StringView, chain: Chains = default): Future[void] {.async.} =
    doAssert false, "you cannot call write of ConnectionAdapter!"

method read*(self: ConnectionAdapter, bytes: int, chain: Chains = default): Future[StringView] {.async.} =
    doAssert false, "you cannot call read of ConnectionAdapter!"


method start(self: ConnectionAdapter){.raises: [].} =
    {.cast(raises: []).}:
        procCall start(Adapter(self))
        trace "starting"

        self.readLoopFut = self.readloop()
        self.writeLoopFut = self.writeloop()
        asyncSpawn self.readLoopFut
        asyncSpawn self.writeLoopFut

proc stop*(self: ConnectionAdapter) =
    proc breakCycle(){.async.} =
        if not isNil(self.readLoopFut): await self.readLoopFut.cancelAndWait()
        if not isNil(self.writeLoopFut): await self.writeLoopFut.cancelAndWait()
        await sleepAsync(5.seconds)
        self.signal(both, breakthrough)

    if not self.stopped:
        trace "stopping"
        self.stopped = true
        if not isNil(self.socket): self.socket.close()
        self.td.unregister(self.td_id)

        asyncSpawn breakCycle()

method signal*(self: ConnectionAdapter, dir: SigDirection, sig: Signals, chain: Chains = default){.raises: [].} =
    if sig == close or sig == stop: self.stop()

    if sig == breakthrough: doAssert self.stopped, "break through signal while still running?"

    procCall signal(Tunnel(self), dir, sig, chain)

    if sig == start: self.start()


