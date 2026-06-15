#!/usr/bin/env python3
"""
CDP Fingerprint Injection Script - Private Browser Edge (stable v1.2).

Called by entrypoint.sh at container startup, or independently by the edge
service whenever a new page target is created.

Flow at startup:
  1. Inject into about:blank page
  2. Navigate to START_URL
  3. Wait for navigation, then re-inject

Environment:
  FINGERPRINT_RUNTIME_CONFIG_BASE64   base64-encoded JSON config (required)
  INTERNAL_DEBUG_PORT                 CDP port (default 19222)
  START_URL                           page to navigate to after injection
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

def inject_page(ws_url):
    try:
        ws=websocket.create_connection(ws_url,timeout=5,suppress_origin=True)
        try:
            ws.send(json.dumps({"id":1,"method":"Runtime.evaluate","params":{"expression":INJECT_JS,"returnByValue":True}}))
            resp=json.loads(ws.recv())
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

ok=inject_page(ws)
print(f"fp_inject [1/3] inject about:blank: {'OK' if ok else 'FAIL'}")

if START and START!="about:blank":
    ok=navigate_page(ws,START)
    print(f"fp_inject [2/3] navigate: {'OK' if ok else 'FAIL'}")
    time.sleep(8)
    pages=get_pages()
    for p in pages:
        if p.get("type")=="page":
            ok=inject_page(p["webSocketDebuggerUrl"])
            print(f"fp_inject [3/3] re-inject: {'OK' if ok else 'FAIL'}")
            break

print("fp_inject: complete")
