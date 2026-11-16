# In-container WebSocket client: python3 ws_attach.py <host> <port> <token|""> <pane_id>  (HOLD=<s> keeps the socket open).
import sys, socket, os, base64, struct, json, time, select
host, port, tok, pane = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4]
s = socket.create_connection((host, port), timeout=10)
key = base64.b64encode(os.urandom(16)).decode()
hdr = f"GET /ws HTTP/1.1\r\nHost: {host}:{port}\r\nOrigin: http://{host}:{port}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n"
if tok: hdr += f"Authorization: Bearer {tok}\r\n"
s.sendall((hdr + "\r\n").encode())
buf = b""
while b"\r\n\r\n" not in buf: 
    d = s.recv(4096)
    if not d: break
    buf += d
head, _, rest = buf.partition(b"\r\n\r\n")
print("handshake:", head.split(b"\r\n")[0].decode())
if b" 101 " not in head.split(b"\r\n")[0]: sys.exit(0)
def send(obj):
    p = json.dumps(obj).encode(); m = os.urandom(4)
    f = bytes([0x81]); n = len(p)
    f += bytes([0x80 | n]) if n < 126 else bytes([0x80|126]) + struct.pack(">H", n)
    s.sendall(f + m + bytes(b ^ m[i%4] for i, b in enumerate(p)))
data = rest
def frames():
    global data
    while True:
        if len(data) >= 2:
            op = data[0] & 0xf; n = data[1] & 0x7f; o = 2
            if n == 126 and len(data) >= 4: n = struct.unpack(">H", data[2:4])[0]; o = 4
            elif n == 127 and len(data) >= 10: n = struct.unpack(">Q", data[2:10])[0]; o = 10
            elif n >= 126: n = None
            if n is not None and len(data) >= o + n:
                p = data[o:o+n]; data = data[o+n:]; yield op, p; continue
        r = select.select([s], [], [], 2)[0]
        if not r: return
        d = s.recv(65536)
        if not d: return
        data += d
def pump(label, secs=3):
    end = time.time() + secs; out = []
    for op, p in frames():
        out.append((op, p))
        if time.time() > end: break
    return out
seen = []
for op, p in pump("init"):
    try: j = json.loads(p); seen.append(j.get("type"))
    except Exception: seen.append(f"op{op}")
print("initial msg types:", seen[:15])
send({"type": "attach", "pane_id": pane, "cols": 100, "rows": 30})
time.sleep(1.5)
send({"type": "input", "pane_id": pane, "text": "echo OVIS_ATTACH_$((6*7))\r"})
txt = b""; types = []
for op, p in pump("attach", 4):
    try:
        j = json.loads(p); types.append(j.get("type"))
        for k in ("data", "text", "chunk", "output"):
            if isinstance(j.get(k), str): txt += j[k].encode()
    except Exception: txt += p
print("after attach types:", sorted(set(map(str, types))))
print("saw OVIS_ATTACH_42 in output:", b"OVIS_ATTACH_42" in txt)
print("output tail:", txt[-80:]); time.sleep(float(os.environ.get("HOLD","0")))
