#!/usr/bin/env python3
"""CDP fingerprint daemon.

设计来源：
- 之前只对当前页面执行 Runtime.evaluate，页面刷新后同一个 target 仍然存在，但注入内容会丢；
- 这会让浏览器在一次会话里出现“首屏是归一化指纹，刷新后又退回裸运行态”的前后不一致；
- 当前 daemon 改为先给 page target 注册 Page.addScriptToEvaluateOnNewDocument，再补一次当前文档注入，
  这样既能覆盖“已经打开的页面”，也能覆盖“同一个 target 后续刷新/重定向的新文档”。

职责边界：
- 只负责给现有 page target 安装和补打指纹归一化脚本；
- 不负责导航业务页面，不负责判断第三方站点是否可访问；
- 失败时只记录日志，不替代 entrypoint 的 CDP 健康检查和上层业务失败收口。
"""

import json
import os
import signal
import subprocess
import sys
import time

import websocket

CDP_PORT = os.environ.get("INTERNAL_DEBUG_PORT", "19222")
FP_B64 = os.environ.get("FINGERPRINT_RUNTIME_CONFIG_BASE64", "")
CDP = f"http://127.0.0.1:{CDP_PORT}"
ONCE = "--once" in sys.argv

if not FP_B64:
    print("fp_daemon: FP_B64 not set")
    sys.exit(0)

for _ in range(40):
    try:
        json.loads(subprocess.check_output(["curl", "-s", f"{CDP}/json/version"], timeout=2))
        break
    except Exception:
        time.sleep(1)
else:
    print("fp_daemon: CDP not ready")
    sys.exit(1)

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
        return json.loads(subprocess.check_output(["curl", "-s", f"{CDP}/json/list"]))
    except Exception:
        return []


def call(ws, method, params, message_id):
    ws.send(json.dumps({"id": message_id, "method": method, "params": params}))
    while True:
        response = json.loads(ws.recv())
        if response.get("id") != message_id:
            continue
        return response


def install_for_page(ws_url):
    try:
        ws = websocket.create_connection(ws_url, timeout=5, suppress_origin=True)
        try:
            page_enable = call(ws, "Page.enable", {}, 1)
            if "error" in page_enable:
                return False, "page-enable-failed"

            register = call(
                ws,
                "Page.addScriptToEvaluateOnNewDocument",
                {"source": INJECT_JS},
                2,
            )
            if "error" in register:
                return False, "register-on-new-document-failed"

            immediate = call(
                ws,
                "Runtime.evaluate",
                {"expression": INJECT_JS, "returnByValue": True},
                3,
            )
            if "error" in immediate:
                return False, "runtime-evaluate-failed"

            return True, "ok"
        finally:
            ws.close()
    except Exception as error:
        return False, str(error)


def install_all(log_each=False):
    success = 0
    seen = 0
    for target in get_pages():
        if target.get("type") != "page":
            continue
        seen += 1
        ok, reason = install_for_page(target["webSocketDebuggerUrl"])
        if ok:
            success += 1
        if log_each:
            print(
                f"fp_daemon: target url={target.get('url', '')[:80]} result={'ok' if ok else reason}",
                flush=True,
            )
    return success, seen


if ONCE:
    success, seen = install_all(log_each=False)
    print(f"fp_daemon --once: installed={success} seen={seen}")
    sys.exit(0)

print("fp_daemon: started", flush=True)
success, seen = install_all(log_each=True)
print(f"fp_daemon: initial installed={success} seen={seen}", flush=True)

known = set()
running = True


def stop(_signum, _frame):
    global running
    running = False


signal.signal(signal.SIGTERM, stop)
signal.signal(signal.SIGINT, stop)

while running:
    try:
        for target in get_pages():
            if target.get("type") != "page":
                continue
            ws_url = target["webSocketDebuggerUrl"]
            if ws_url in known:
                continue
            known.add(ws_url)
            ok, reason = install_for_page(ws_url)
            print(
                f"fp_daemon: discovered url={target.get('url', '')[:80]} result={'ok' if ok else reason}",
                flush=True,
            )
    except Exception as error:
        print(f"fp_daemon: loop error {error}", flush=True)
    time.sleep(2)

print("fp_daemon: stopped")
