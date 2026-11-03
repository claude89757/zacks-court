// Screenshot harness: a fake camera socket that replays the labelled demo record. Not a measurement.
(function(){
  const q = new URLSearchParams(location.search);
  const data = fetch("demo-rows.json").then(r => r.json());
  const realFetch = window.fetch.bind(window);
  window.fetch = (url, opts) => String(url).startsWith("/api") ? Promise.resolve(new Response('{"sessions":[]}', {status:200, headers:{"content-type":"application/json"}})) : realFetch(url, opts);
  class FakeSocket {
    constructor(){ this.readyState = 0; setTimeout(() => this.open(), 30); }
    async open(){
      const d = await data; this.readyState = 1;
      const msg = (kind, body) => this.onmessage && this.onmessage({ data: JSON.stringify({ kind, body, t: Date.now() }) });
      msg("auth", { ok: true, access: "demo" });
      msg("hello", { session: null, camera: "演示机位" });
      const hawk = { enabled: true, format: "singles", farHalf: false, voice: true };
      msg("status", { hawkEye: hawk, busy: false, sessionID: null, analysisRunning: true, capturing: true, fps: 60 });
      msg("analysis", { events: d.older, resync: true, part: 0 });
      setTimeout(() => {
        msg("analysis", { events: [d.newest] });
        setTimeout(() => {
          const v = q.get("view");
          if (v === "board" || v === "serve" || v === "challenge") document.getElementById("board-open").click();
          if (v === "serve") document.querySelector('[data-mode="serve"]').click();
          if (v === "challenge") setTimeout(() => document.getElementById("board-challenge").click(), 200);
        }, 300);
      }, 300);
      setInterval(() => msg("status", { hawkEye: hawk, busy: false, sessionID: null, analysisRunning: true, capturing: true, fps: 60 }), 1000);
    }
    send(){} close(){}
  }
  window.WebSocket = FakeSocket; window.WebSocket.OPEN = 1;
  history.replaceState(null, "", location.pathname + location.search + "#t=demo");
})();
