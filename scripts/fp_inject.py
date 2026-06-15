#!/usr/bin/env python3
"""
CDP Fingerprint Injection Script - Private Browser Edge.

设计来源：
- 旧链路只在当前页面执行 Runtime.evaluate，遇到刷新或重定向时，新文档会失去归一化脚本；
- 当前脚本在启动阶段先注册 Page.addScriptToEvaluateOnNewDocument，再对当前文档补打一轮，
  这样 about:blank、首次导航和同一 target 内的新文档都能保持同一份注入逻辑。

职责边界：
- 只负责容器冷启动时的第一轮注入和首个 START_URL 导航；
- 不负责长期监听页面变化，那部分交给 fp_daemon.py；
- 不负责站点业务判断，导航失败只输出启动日志，由上层按容器失败事实处理。
"""
import json, sys, os, subprocess, time, websocket

CDP_PORT = os.environ.get("INTERNAL_DEBUG_PORT", "19222")
FP_B64   = os.environ.get("FINGERPRINT_RUNTIME_CONFIG_BASE64", "")
START    = os.environ.get("START_URL", "about:blank")
CDP      = f"http://127.0.0.1:{CDP_PORT}"

if not FP_B64:
    print("fp_inject: FINGERPRINT_RUNTIME_CONFIG_BASE64 not set, skipping")
    sys.exit(0)

# Wait for CDP
for _ in range(40):
    try:
        r = subprocess.check_output(["curl","-s",f"{CDP}/json/version"],timeout=2)
        json.loads(r); break
    except: time.sleep(1)
else:
    print("fp_inject: ERROR CDP not ready", file=sys.stderr); sys.exit(1)

# Minified injection script
INJECT_JS = """(function(){
var d='%s';var c=JSON.parse(atob(d));
var g=function(t,p,v){try{Object.defineProperty(t,p,{get:function(){return v;},configurable:true,enumerable:false})}catch(e){}};
var r=function(){return Promise.reject(new DOMException("d","NotAllowedError"));};
g(window,"RTCPeerConnection",void 0);g(window,"MediaStream",void 0);
if(navigator.mediaDevices){g(navigator.mediaDevices,"getUserMedia",r);g(navigator.mediaDevices,"enumerateDevices",async function(){return[];})}
g(navigator,"getUserMedia",r);
if(c.userAgent)g(navigator,"userAgent",c.userAgent);if(c.platform)g(navigator,"platform",c.platform);
if(c.language)g(navigator,"language",c.language);if(c.languages)g(navigator,"languages",c.languages.slice());
if(c.deviceMemory)g(navigator,"deviceMemory",c.deviceMemory);
if(c.hardwareConcurrency)g(navigator,"hardwareConcurrency",c.hardwareConcurrency);
if(c.maxTouchPoints!=null)g(navigator,"maxTouchPoints",c.maxTouchPoints);
if(screen&&c.screen){if(c.screen.width)g(screen,"width",c.screen.width);if(c.screen.height)g(screen,"height",c.screen.height);}
if(screen&&c.availableScreen){if(c.availableScreen.width)g(screen,"availWidth",c.availableScreen.width);if(c.availableScreen.height)g(screen,"availHeight",c.availableScreen.height);}
if(c.colorDepth){g(screen,"colorDepth",c.colorDepth);g(screen,"pixelDepth",c.colorDepth);}
var n=navigator.connection||navigator.mozConnection||navigator.webkitConnection;
if(n&&c.connection){if(c.connection.effectiveType)g(n,"effectiveType",c.connection.effectiveType);if(c.connection.rtt)g(n,"rtt",c.connection.rtt);if(c.connection.downlink)g(n,"downlink",c.connection.downlink);}
})();""" % FP_B64

def get_pages():
    try:
        return json.loads(subprocess.check_output(["curl","-s",f"{CDP}/json/list"]))
    except: return []

def call(ws, method, params, msg_id):
    ws.send(json.dumps({"id": msg_id, "method": method, "params": params}))
    while True:
        resp = json.loads(ws.recv())
        if resp.get("id") != msg_id:
            continue
        return resp


def install_page(ws_url):
    try:
        ws=websocket.create_connection(ws_url,timeout=5,suppress_origin=True)
        try:
            page_enable = call(ws, "Page.enable", {}, 1)
            if "error" in page_enable:
                return False
            register = call(ws, "Page.addScriptToEvaluateOnNewDocument", {"source": INJECT_JS}, 2)
            if "error" in register:
                return False
            resp = call(ws, "Runtime.evaluate", {"expression": INJECT_JS, "returnByValue": True}, 3)
            return "error" not in resp
        finally: ws.close()
    except: return False

def navigate_page(ws_url,url):
    try:
        ws=websocket.create_connection(ws_url,timeout=10,suppress_origin=True)
        try:
            ws.send(json.dumps({"id":1,"method":"Page.enable"}))
            json.loads(ws.recv())
            ws.send(json.dumps({"id":2,"method":"Page.navigate","params":{"url":url}}))
            json.loads(ws.recv())
            return True
        finally: ws.close()
    except: return False

# Startup flow
pages=get_pages()
page_targets=[p for p in pages if p.get("type")=="page"]
if not page_targets:
    print("fp_inject: ERROR no pages",file=sys.stderr); sys.exit(1)

first=page_targets[0]
ws=first["webSocketDebuggerUrl"]

ok=install_page(ws)
print(f"fp_inject [1/3] install about:blank: {'OK' if ok else 'FAIL'}")

if START and START!="about:blank":
    ok=navigate_page(ws,START)
    print(f"fp_inject [2/3] navigate: {'OK' if ok else 'FAIL'}")
    time.sleep(8)
    pages=get_pages()
    for p in pages:
        if p.get("type")=="page":
            ok=install_page(p["webSocketDebuggerUrl"])
            print(f"fp_inject [3/3] install after navigate: {'OK' if ok else 'FAIL'}")
            break

print("fp_inject: complete")
