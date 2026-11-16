# In-container HTTP probe: python3 http_probe.py <host> <port> [token]. Prints status codes only; never the token.
import sys, json, http.client, base64, os, socket, struct
host, port = sys.argv[1], int(sys.argv[2]); tok = sys.argv[3] if len(sys.argv)>3 else ""
def req(path, method="GET", hdr=None, body=None):
    c = http.client.HTTPConnection(host, port, timeout=10)
    h = dict(hdr or {})
    c.request(method, path, body=body, headers=h); r = c.getresponse(); d = r.read()
    return r.status, d[:600].decode(errors="replace")
print("health noauth      ", req("/api/health"))
print("session noauth     ", req("/api/session")[0])
print("session badtoken   ", req("/api/session", hdr={"Authorization":"Bearer wrong"})[0])
if tok:
    s, d = req("/api/session", hdr={"Authorization":"Bearer "+tok})
    print("session token      ", s)
    c = http.client.HTTPConnection(host, port, timeout=10); c.request("GET","/api/session",headers={"Authorization":"Bearer "+tok}); full=json.loads(c.getresponse().read())
    sn = full["snapshot"]
    print("snapshot keys", list(sn.keys()))
    print("workspaces:", [w["label"] for w in sn["workspaces"]], "panes:", [p["pane_id"] for p in sn["panes"]])
