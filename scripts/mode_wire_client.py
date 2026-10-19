"""Protocol-v3 real TLS diagnostic client. No keys/input content logged."""
import hashlib, io, json, secrets, socket, ssl, struct, time

def listening_pids(port):
    # Read the kernel listener table. A refused connect() on Windows can spend
    # seconds retrying after the listener is already gone, distorting timing.
    import ctypes
    from ctypes import wintypes
    class Row(ctypes.Structure):
        _fields_=[(name,wintypes.DWORD) for name in ('state','local_addr','local_port','remote_addr','remote_port','pid')]
    size=wintypes.DWORD()
    query=ctypes.windll.iphlpapi.GetExtendedTcpTable
    code=query(None,ctypes.byref(size),False,socket.AF_INET,3,0)
    if code not in (0,122) or size.value>1024*1024:raise RuntimeError('TCP table unavailable')
    data=ctypes.create_string_buffer(size.value)
    if query(data,ctypes.byref(size),False,socket.AF_INET,3,0)!=0:raise RuntimeError('TCP listener query failed')
    count=struct.unpack_from('<I',data.raw)[0];result=set()
    for index in range(count):
        row=Row.from_buffer(data,4+index*ctypes.sizeof(Row))
        if row.state==2 and socket.ntohs(row.local_port & 65535)==port:result.add(row.pid)
    return result

def string(value):
    value=value.encode('utf-8');return struct.pack('<Q',len(value))+value
def hello(ticket,nonce,mode,certificate=''):
    return (struct.pack('<IH',0,3)+string('mode-wire-test')+string('diagnostic')+b'\0'+struct.pack('<I',7)
        +b'\1'+string(ticket)+string(nonce)+string(mode)+string(certificate))
def send(sock,payload):sock.sendall(struct.pack('>I',len(payload))+payload)
def exact(sock,count):
    result=b''
    while len(result)<count:
        data=sock.recv(count-len(result))
        if not data:raise EOFError('Host closed')
        result+=data
    return result
def receive(sock):
    length=struct.unpack('>I',exact(sock,4))[0]
    assert 0<length<=32*1024*1024
    return exact(sock,length)
def connect(port,fingerprint):
    context=ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT);context.check_hostname=False;context.verify_mode=ssl.CERT_NONE
    context.set_alpn_protocols(['yuanlian/1'])
    sock=context.wrap_socket(socket.create_connection(('127.0.0.1',port),timeout=8),server_hostname='yuanlian.local')
    assert hashlib.sha256(sock.getpeercert(binary_form=True)).hexdigest()==fingerprint.replace(':','').lower()
    return sock
class Reader:
    def __init__(self,data):self.data=data;self.at=0
    def take(self,n):value=self.data[self.at:self.at+n];self.at+=n;assert len(value)==n;return value
    def unpack(self,fmt):return struct.unpack(fmt,self.take(struct.calcsize(fmt)))[0]
    def string(self):return self.take(self.unpack('<Q')).decode('utf-8')

def flow_test(api,device_id,port,fingerprint,file_payload):
    nonce=secrets.token_hex(32)
    ticket=api('POST',f'/api/v1/devices/{device_id}/session-ticket',{'nonce':nonce,'mode':'flow'})
    # A valid flow ticket must not authorize quality, and denial must not consume it.
    with connect(port,fingerprint) as sock:
        send(sock,hello(ticket['ticket'],nonce,'quality'))
        error=Reader(receive(sock));assert error.unpack('<I')==4
    with connect(port,fingerprint) as sock:
        send(sock,hello(ticket['ticket'],nonce,'flow'))
        welcome=Reader(receive(sock));assert welcome.unpack('<I')==0;assert welcome.unpack('<H')==3
        welcome.string();welcome.string();width=welcome.unpack('<I');height=welcome.unpack('<I');welcome.take(1)
        assert welcome.string()=='flow'
        caps=Reader(receive(sock));assert caps.unpack('<I')==6;assert caps.unpack('<B')==1
        send(sock,struct.pack('<IQ',6,123)+string('payload.bin'))
        start=time.monotonic();last_ping=start;received=0;frames=0;tile_bytes=0;pings={};latencies=[];download=bytearray();done=False;nonce_id=0
        first_tile=None
        while time.monotonic()-start<25 or not done:
            now=time.monotonic()
            if now-start>40:raise AssertionError('flow file transfer timed out')
            if now-last_ping>=1:
                nonce_id+=1;pings[nonce_id]=now;send(sock,struct.pack('<IQ',3,nonce_id));last_ping=now
            data=receive(sock);received+=len(data)+4
            reader=Reader(data);tag=reader.unpack('<I')
            if tag==13:
                reader.unpack('<Q');reader.unpack('<I');reset=reader.unpack('<B')
                new_width=reader.unpack('<I');new_height=reader.unpack('<I')
                if (new_width,new_height)!=(width,height):assert reset; width,height=new_width,new_height
                count=reader.unpack('<Q');assert count==1
                x,y,w,h=[reader.unpack('<I') for _ in range(4)];jpeg=reader.take(reader.unpack('<Q'))
                assert 0<w<=64 and 0<h<=64 and x+w<=width and y+h<=height and len(data)<=12288
                assert jpeg[:2]==b'\xff\xd8' and jpeg[-2:]==b'\xff\xd9'
                first_tile=first_tile or jpeg;frames+=1;tile_bytes+=len(jpeg)
            elif tag==3:
                ping=reader.unpack('<Q')
                if ping in pings:latencies.append(time.monotonic()-pings.pop(ping))
            elif tag==8:
                assert reader.unpack('<Q')==123;assert reader.unpack('<Q')==len(download)
                chunk=reader.take(reader.unpack('<Q'));assert len(chunk)<=8192;download.extend(chunk)
            elif tag==10:
                assert reader.unpack('<Q')==123;reader.string();assert reader.unpack('<Q')==len(file_payload)
                assert reader.string()==hashlib.sha256(file_payload).hexdigest();assert len(download)==len(file_payload);done=True
            elif tag in (4,5,11):raise AssertionError('unexpected flow error/termination')
        elapsed=time.monotonic()-start
        assert done and bytes(download)==file_payload and frames>50 and tile_bytes>0 and latencies
        assert received/elapsed<102000,(received,elapsed)
        p95=sorted(latencies)[int((len(latencies)-1)*.95)]
        assert p95<1.5,p95
        print(json.dumps({'flow_seconds':round(elapsed,2),'framed_bytes_per_second':round(received/elapsed),
            'actual_screen_tiles':frames,'download_sha256_match':True,'ping_p95_seconds':round(p95,3)}),flush=True)
        send(sock,struct.pack('<I',4))
    # The same ticket is unusable after the real successful session.
    with connect(port,fingerprint) as sock:
        send(sock,hello(ticket['ticket'],nonce,'flow'))
        assert struct.unpack('<I',receive(sock)[:4])[0]==4
    print('MODE_BINDING_AND_REPLAY_PASS',flush=True)
