#!/usr/bin/env python3
"""CDP Fingerprint Injection Daemon - monitors new pages and injects FP normalization.
Run: fp_daemon.py           # daemon mode (persistent)
     fp_daemon.py --once    # inject current pages only
"""
import json,sys,os,subprocess,time,websocket,signal

CDP_PORT=os.environ.get("INTERNAL_DEBUG_PORT","19222")
FP_B64=os.environ.get("FINGERPRINT_RUNTIME_CONFIG_BASE64","")
CDP=f"http://127.0.0.1:{CDP_PORT}"
ONCE="--once" in sys.argv

if not FP_B64: print("fp_daemon: FP_B64 not set"); sys.exit(0)

for _ in range(40):
    try:json.loads(subprocess.check_output(["curl","-s",f"{CDP}/json/version"],timeout=2));break
    except:time.sleep(1)
else:print("CDP not ready");sys.exit(1)

INJECT_JS="""(function(){
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
})();"""%FP_B64

def get_pages():
    try:return json.loads(subprocess.check_output(["curl","-s",f"{CDP}/json/list"]))
    except:return[]

def inject(ws_url):
    try:
        ws=websocket.create_connection(ws_url,timeout=5,suppress_origin=True)
        try:
            ws.send(json.dumps({"id":1,"method":"Runtime.evaluate","params":{"expression":INJECT_JS,"returnByValue":True}}))
            return "error" not in json.loads(ws.recv())
        finally:ws.close()
    except:return False

def inject_all():
    n=0
    for t in get_pages():
        if t.get("type")=="page" and inject(t["webSocketDebuggerUrl"]):n+=1
    return n

if ONCE:
    n=inject_all();print(f"fp_daemon --once: {n} pages");sys.exit(0)

print("fp_daemon: started",flush=True)
inject_all()
known=set()
running=True
def stop(s,f):global running;running=False
signal.signal(signal.SIGTERM,stop);signal.signal(signal.SIGINT,stop)

while running:
    try:
        for t in get_pages():
            if t.get("type")=="page":
                ws=t["webSocketDebuggerUrl"]
                if ws not in known:
                    known.add(ws)
                    inject(ws)
                    print(f"fp_daemon: new page {t.get('url','')[:60]}",flush=True)
    except:pass
    time.sleep(2)
print("fp_daemon: stopped")
