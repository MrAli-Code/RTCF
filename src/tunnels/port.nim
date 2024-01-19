import tunnel
import std/[endians]

from adapters/connection import ConnectionAdapter, getRawSocket
from chronos/osdefs import SocketHandle,SockLen,getsockopt

logScope:
    topic = "Port Tunnel"


#     1    2    3    4    5    6    7
# ----------------------------------
#   port    |
# ----------------------------------
#   Port    |
# ----------------------------------
#
#   This tunnel adds port header, finds the right value for the port
#   and when Reading from it , it extcarcts port header and saves it
#   and provide interface for other tunnel/adapters to get that port
#
#   This tunnel requires ConnectionAdapter
#



const SO_ORIGINAL_DST* = 80
const IP6T_SO_ORIGINAL_DST* = 80
const SOL_IP* = 0
const SOL_IPV6* = 41

type
    PortTunnel* = ref object of Tunnel
        writePort: Port
        readPort: Port
        multiport: bool
        flag_readmode: bool

const PortTunnelHeaderSize = sizeof(Port)

method init(self: PortTunnel, name: string, multiport: bool, writeport: Port){.base, raises: [], gcsafe.} =
    procCall init(Tunnel(self), name, hsize = PortTunnelHeaderSize)
    self.writeport = writeport
    self.multiport = multiport

proc newPortTunnel*(name: string = "PortTunnel", multiport: bool, writeport: Port = 0.Port): PortTunnel =
    result = new PortTunnel
    result.init(name, multiport, writeport)
    trace "Initialized", name

method write*(self: PortTunnel, data: StringView, chain: Chains = default): Future[void] {.raises: [], gcsafe.} =
    setWriteHeader(self, data):
        copyMem(self.getWriteHeader, addr self.writePort, self.hsize)
        trace "Appended ", header = $self.writePort, name = self.name

    procCall write(Tunnel(self), self.writeLine)

method read*(self: PortTunnel, bytes: int, chain: Chains = default): Future[StringView] {.async.} =
    setReadHeader(self, await procCall read(Tunnel(self), bytes+self.hsize))
    copyMem(addr self.readPort, self.getReadHeader, self.hsize)
    trace "extracted ", header = $self.readPort

    if  self.writeport != 0.Port :
        assert self.readPort == self.writePort

    if self.flag_readmode and self.writeport == 0.Port: self.writeport = self.readPort

    return self.readLine


proc start(self: PortTunnel) =
    {.cast(raises: []).}:
        trace "starting"
        var (target, _) = self.findByType(ConnectionAdapter, both, Chains.default)
        # doAssert target != nil, "Port Tunnel could not find connection adapter on default chain!"
        # echo "found dir was: ", $dir
        if target == nil:
            #After gfw, port must first be read from the flow
            self.flag_readmode = true
            
        else:
            #Before GFW , when multi port = get port from socket ; else use writeport

            if self.multiport:
                # assert self.writePort == 0.Port
                var sock = target.getRawSocket()
                var objbuf = newString(len = 28)
                var size = SockLen(if isV4Mapped(sock.remoteAddress): 16 else: 28)
                let sol = int(if isV4Mapped(sock.remoteAddress): SOL_IP else: SOL_IPV6)
                # getSockOpt(sock.fd, sol, int(SO_ORIGINAL_DST), cast[var pointer](addr objbuf[0]), size) chronos mistakes ?
                if -1 == osdefs.getsockopt(SocketHandle(sock.fd), cint(sol), cint(SO_ORIGINAL_DST),
                              addr objbuf[0], addr(size)):
                    error "multiport failure getting origin port. !"
                    self.writePort = 65500.Port
                    return
                    # raise newException(AssertionDefect, "multiport failure getting origin port. !")
                else:
                    bigEndian16(addr self.writePort, addr objbuf[2])

                trace "Multiport ", port = self.writePort
        


method signal*(self: PortTunnel, dir: SigDirection, sig: Signals, chain: Chains = default) =
    procCall signal(Tunnel(self), dir, sig, chain)
    if sig == start: self.start()



proc getReadPort*(self: PortTunnel): Port = self.readPort

