// Leadgen — Ops Console (internal operator dashboard). Deployed instance: k3EJWaGRnGg8tl3p.
// Live URL: https://n8n.hiwebenterprise.com/webhook/leadgen-console (prompts once for x-leadgen-key).
// A self-contained SPA served by n8n, reading the prod ledger (leadgen namespace) over the
// workers' existing SELECT grant (NO DML — read-only monitoring). Three GET webhooks:
//   /webhook/leadgen-console        -> HTML shell (SPA; prompts once for the access key)
//   /webhook/leadgen-console-data   -> JSON: fleet KPIs, campaigns (campaign_progress + per-class
//                                      counts + spend), work-queue matrix, stuck count
//   /webhook/leadgen-console-leads?campaign=<uuid> -> JSON: that campaign's leads with current
//                                      assessment (4 fit scores + opp/contact/conf), a rolled-up
//                                      jsonb of latest evidence signals, and the report_url
// The "New campaign" form POSTs to the EXISTING intake API (/webhook/leadgen-intake-api) — no new
// mutation surface. Data + leads endpoints require header x-leadgen-key (same shared secret as the
// intake API); redacted here to <<INTAKE_API_KEY>>, set on the deployed instance via update_workflow.
// Visual identity: "situation room" console — Fraunces display, IBM Plex Sans/Mono; cool-black
// ground + beacon-azure accent; heat is semantic (hot/warm/cold/dq), separate from the accent.
import { workflow, node, trigger, sticky, newCredential, ifElse, expr } from '@n8n/workflow-sdk';

// ---------- 1) Console page (HTML shell) ----------
const hookPage = trigger({ type: 'n8n-nodes-base.webhook', version: 2.1, config: { name: 'Console Page', position: [200, 120], parameters: { httpMethod: 'GET', path: 'leadgen-console', responseMode: 'responseNode' } }, output: [{ headers: {}, query: {} }] });

const PAGE = `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex, nofollow">
<title>HiLeadDiscovery — Ops Console</title>
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link href="https://fonts.googleapis.com/css2?family=Fraunces:opsz,wght@9..144,500;9..144,600&family=IBM+Plex+Mono:wght@400;500;600&family=IBM+Plex+Sans:wght@400;500;600&display=swap" rel="stylesheet">
<style>
:root{
  --bg:#0f1216; --panel:#161a21; --panel2:#1c212a; --line:#262d38; --line2:#333c4a;
  --ink:#e8ecf2; --muted:#8b95a4; --faint:#5c6675;
  --accent:#4f7cf0; --accent-ink:#cdd9ff; --accent-dim:#22304f;
  --hot:#e0563b; --warm:#e0a13b; --cold:#6b8bb5; --dq:#767f8c;
  --good:#3fae7a; --warn:#e0a13b; --crit:#e0563b;
  --shadow:0 1px 0 rgba(255,255,255,.02), 0 8px 30px rgba(0,0,0,.35);
  --r:12px;
}
:root[data-theme="light"]{
  --bg:#f5f7fa; --panel:#ffffff; --panel2:#eef1f6; --line:#e2e7ee; --line2:#d3dae4;
  --ink:#1a2029; --muted:#5c6675; --faint:#98a2b0;
  --accent:#3760d8; --accent-ink:#22304f; --accent-dim:#dfe7fb;
  --hot:#c8452b; --warm:#b47613; --cold:#4f6f9c; --dq:#6b7480;
  --shadow:0 1px 0 rgba(0,0,0,.02), 0 10px 30px rgba(18,30,55,.08);
}
@media (prefers-color-scheme: light){
  :root:not([data-theme]){
    --bg:#f5f7fa; --panel:#ffffff; --panel2:#eef1f6; --line:#e2e7ee; --line2:#d3dae4;
    --ink:#1a2029; --muted:#5c6675; --faint:#98a2b0;
    --accent:#3760d8; --accent-ink:#22304f; --accent-dim:#dfe7fb;
    --hot:#c8452b; --warm:#b47613; --cold:#4f6f9c; --dq:#6b7480;
    --shadow:0 1px 0 rgba(0,0,0,.02), 0 10px 30px rgba(18,30,55,.08);
  }
}
*{box-sizing:border-box}
html,body{margin:0;padding:0}
body{background:var(--bg);color:var(--ink);font-family:"IBM Plex Sans",system-ui,-apple-system,Segoe UI,Roboto,sans-serif;font-size:14px;line-height:1.45;-webkit-font-smoothing:antialiased}
.mono{font-family:"IBM Plex Mono",ui-monospace,monospace;font-variant-numeric:tabular-nums}
a{color:var(--accent);text-decoration:none}
a:hover{text-decoration:underline}
button{font-family:inherit;cursor:pointer}
:focus-visible{outline:2px solid var(--accent);outline-offset:2px;border-radius:6px}

/* top bar */
header{position:sticky;top:0;z-index:20;display:flex;align-items:center;gap:16px;padding:14px 22px;background:color-mix(in srgb,var(--bg) 88%, transparent);backdrop-filter:blur(10px);border-bottom:1px solid var(--line)}
.brand{display:flex;flex-direction:column;line-height:1}
.brand b{font-family:"Fraunces",Georgia,serif;font-weight:600;font-size:20px;letter-spacing:.2px}
.brand span{font-size:10px;letter-spacing:.28em;text-transform:uppercase;color:var(--faint);margin-top:3px}
.grow{flex:1}
.tbtn{background:var(--panel);border:1px solid var(--line);color:var(--ink);border-radius:9px;padding:8px 12px;font-size:13px;display:inline-flex;align-items:center;gap:7px}
.tbtn:hover{border-color:var(--line2)}
.tbtn.primary{background:var(--accent);border-color:var(--accent);color:#fff}
.tbtn.primary:hover{filter:brightness(1.06)}
.tbtn.ghost{background:transparent}
.segbtn{flex:1;justify-content:center}
.segbtn.on{background:var(--accent);border-color:var(--accent);color:#fff}

/* KPI strip */
.kpis{display:grid;grid-template-columns:repeat(8,1fr);gap:10px;padding:18px 22px 6px}
.kpi{background:var(--panel);border:1px solid var(--line);border-radius:var(--r);padding:12px 14px;position:relative;overflow:hidden}
.kpi .n{font-family:"Fraunces",Georgia,serif;font-weight:600;font-size:26px;line-height:1;letter-spacing:.3px}
.kpi .l{font-size:10.5px;letter-spacing:.14em;text-transform:uppercase;color:var(--muted);margin-top:7px}
.kpi.heat-hot .n{color:var(--hot)} .kpi.heat-warm .n{color:var(--warm)}
.kpi.heat-cold .n{color:var(--cold)} .kpi.heat-dq .n{color:var(--dq)}
.kpi.alert{border-color:var(--crit)} .kpi.alert .n{color:var(--crit)}
.kpi .rail{position:absolute;left:0;top:0;bottom:0;width:3px;background:var(--line2)}
.kpi.heat-hot .rail{background:var(--hot)} .kpi.heat-warm .rail{background:var(--warm)}
.kpi.heat-cold .rail{background:var(--cold)} .kpi.heat-dq .rail{background:var(--dq)}

/* layout */
main{display:grid;grid-template-columns:320px 1fr;gap:16px;padding:14px 22px 60px;align-items:start}
.side{position:sticky;top:82px;display:flex;flex-direction:column;gap:10px}
.side h2, .board h2{font-size:11px;letter-spacing:.16em;text-transform:uppercase;color:var(--muted);margin:2px 2px 4px;font-weight:600}
.clist{display:flex;flex-direction:column;gap:8px;max-height:calc(100vh - 160px);overflow:auto;padding-right:2px}
.camp{text-align:left;width:100%;background:var(--panel);border:1px solid var(--line);border-radius:var(--r);padding:11px 12px;display:flex;flex-direction:column;gap:8px;color:inherit}
.camp:hover{border-color:var(--line2)}
.camp.sel{border-color:var(--accent);box-shadow:inset 0 0 0 1px var(--accent)}
.camp .top{display:flex;align-items:baseline;justify-content:space-between;gap:8px}
.camp .ct{font-weight:600;font-size:14px;text-transform:capitalize}
.camp .cg{font-size:11.5px;color:var(--muted)}
.camp .meta{display:flex;justify-content:space-between;font-size:11px;color:var(--faint)}
.stack{display:flex;height:6px;border-radius:4px;overflow:hidden;background:var(--panel2)}
.stack i{display:block;height:100%}
.stack i.hot{background:var(--hot)} .stack i.warm{background:var(--warm)}
.stack i.cold{background:var(--cold)} .stack i.dq{background:var(--dq)}

/* status pills */
.pill{font-size:10.5px;font-weight:600;letter-spacing:.03em;padding:2px 8px;border-radius:999px;border:1px solid transparent;white-space:nowrap;display:inline-flex;align-items:center;gap:5px}
.st-complete{color:var(--good);background:color-mix(in srgb,var(--good) 15%,transparent);border-color:color-mix(in srgb,var(--good) 35%,transparent)}
.st-run{color:var(--accent-ink);background:var(--accent-dim);border-color:color-mix(in srgb,var(--accent) 40%,transparent)}
.st-wait{color:var(--warn);background:color-mix(in srgb,var(--warn) 15%,transparent);border-color:color-mix(in srgb,var(--warn) 35%,transparent)}
.st-fail{color:var(--crit);background:color-mix(in srgb,var(--crit) 15%,transparent);border-color:color-mix(in srgb,var(--crit) 35%,transparent)}
.st-archived{color:var(--crit);background:rgba(239,68,68,0.12);border-color:rgba(239,68,68,0.4)}
.st-idle{color:var(--muted);background:var(--panel2);border-color:var(--line)}

/* archived campaign styling */
.camp.is-archived{border-left:4px solid var(--crit)!important;background:color-mix(in srgb,var(--crit) 5%,var(--panel))!important}
.rows.is-archived{border:2px dashed rgba(239,68,68,0.4)!important;border-radius:12px;background:rgba(239,68,68,0.015);padding:12px}
.rows.is-archived .lead{border-color:rgba(239,68,68,0.25)!important;box-shadow:0 1px 4px rgba(239,68,68,0.05)}

/* lead board */
.board{min-width:0}
.bhead{display:flex;align-items:center;gap:12px;margin-bottom:12px;flex-wrap:wrap}
.bhead .ttl{font-family:"Fraunces",Georgia,serif;font-size:22px;font-weight:600;text-transform:capitalize}
.rows{display:flex;flex-direction:column;gap:8px}
.lead{background:var(--panel);border:1px solid var(--line);border-radius:var(--r);padding:12px 14px;display:grid;grid-template-columns:26px 1fr 132px 88px auto;gap:14px;align-items:center;box-shadow:var(--shadow)}
.lead:hover{border-color:var(--line2)}
.rank{font-family:"Fraunces",Georgia,serif;font-size:15px;color:var(--faint);text-align:right}
.who{min-width:0}
.who .nm{font-weight:600;font-size:14.5px;display:flex;align-items:center;gap:8px;flex-wrap:wrap}
.who .sub{font-size:12px;color:var(--muted);margin-top:2px;display:flex;gap:10px;flex-wrap:wrap}
.who .sub a{color:var(--muted)} .who .sub a:hover{color:var(--accent)}
.heat{width:9px;height:9px;border-radius:3px;display:inline-block;flex:none}
.heat.hot{background:var(--hot)} .heat.warm{background:var(--warm)}
.heat.cold{background:var(--cold)} .heat.dq{background:var(--dq)}
.htag{font-size:10px;font-weight:600;text-transform:uppercase;letter-spacing:.08em;padding:1px 6px;border-radius:5px}
.htag.hot{color:var(--hot);background:color-mix(in srgb,var(--hot) 16%,transparent)}
.htag.warm{color:var(--warm);background:color-mix(in srgb,var(--warm) 16%,transparent)}
.htag.cold{color:var(--cold);background:color-mix(in srgb,var(--cold) 16%,transparent)}
.htag.dq{color:var(--dq);background:color-mix(in srgb,var(--dq) 16%,transparent)}

/* opportunity gauge */
.opp{display:flex;flex-direction:column;gap:5px}
.opp .val{font-family:"Fraunces",Georgia,serif;font-size:19px;line-height:1}
.opp .bar{position:relative;height:6px;border-radius:4px;background:var(--panel2);overflow:visible}
.opp .fill{position:absolute;left:0;top:0;bottom:0;border-radius:4px}
.opp .tick{position:absolute;top:-2px;bottom:-2px;width:1px;background:var(--faint);left:45%}
.opp small{font-size:9.5px;color:var(--faint);letter-spacing:.1em;text-transform:uppercase}

/* fit strip */
.fit{display:flex;gap:5px;align-items:flex-end;height:36px}
.fit .col{display:flex;flex-direction:column;align-items:center;gap:3px;width:16px}
.fit .track{width:10px;height:26px;background:var(--panel2);border-radius:3px;display:flex;align-items:flex-end;overflow:hidden}
.fit .seg{width:100%;background:var(--line2);border-radius:3px}
.fit .col.best .seg{background:var(--accent)}
.fit .cl{font-size:8.5px;color:var(--faint);letter-spacing:.02em}
.fit .col.best .cl{color:var(--accent-ink)}

/* chips */
.chips{display:flex;gap:6px;flex-wrap:wrap;justify-content:flex-end;max-width:520px}
.chip{font-size:11px;padding:4px 9px;border-radius:7px;border:1px solid var(--line);background:var(--panel2);color:var(--ink);display:inline-flex;align-items:center;gap:5px;white-space:nowrap;cursor:pointer;font-family:inherit}
.chip.ember{border-color:color-mix(in srgb,var(--hot) 45%,transparent);color:var(--hot);background:color-mix(in srgb,var(--hot) 12%,transparent)}
.chip.gold{border-color:color-mix(in srgb,var(--warm) 45%,transparent);color:var(--warm);background:color-mix(in srgb,var(--warm) 12%,transparent)}
.chip.leaf{border-color:color-mix(in srgb,var(--good) 45%,transparent);color:var(--good);background:color-mix(in srgb,var(--good) 12%,transparent)}
.chip.mut{color:var(--muted)}
.chip.rep{border-color:var(--accent);color:var(--accent-ink);background:var(--accent-dim)}
.chip.act-log{border-color:color-mix(in srgb,var(--warn) 45%,transparent);color:var(--warn);background:var(--panel2)}
.chip.act-arc{border-color:color-mix(in srgb,var(--crit) 45%,transparent);color:var(--crit);background:color-mix(in srgb,var(--crit) 10%,transparent);font-weight:600}
.chip.act-arc:hover{background:color-mix(in srgb,var(--crit) 25%,transparent)}

/* fleet + modal + gate */
.overlay{position:fixed;inset:0;background:rgba(6,9,14,.6);backdrop-filter:blur(3px);z-index:40;display:flex;align-items:flex-start;justify-content:center;padding:60px 20px;overflow:auto}
.sheet{background:var(--panel);border:1px solid var(--line2);border-radius:16px;box-shadow:var(--shadow);width:100%;max-width:560px;padding:22px 24px}
.sheet h3{font-family:"Fraunces",Georgia,serif;font-weight:600;font-size:20px;margin:0 0 4px}
.sheet p.hint{color:var(--muted);font-size:12.5px;margin:0 0 16px}
.field{display:flex;flex-direction:column;gap:5px;margin-bottom:13px}
.field label{font-size:11px;letter-spacing:.1em;text-transform:uppercase;color:var(--muted);font-weight:600}
.field input,.field select{background:var(--bg);border:1px solid var(--line);color:var(--ink);border-radius:9px;padding:9px 11px;font-size:14px;font-family:inherit}
.field input:focus,.field select:focus{border-color:var(--accent);outline:none}
.grid2{display:grid;grid-template-columns:1fr 1fr;gap:13px}
.rowbtns{display:flex;gap:10px;justify-content:flex-end;margin-top:6px}
.msg{font-size:12.5px;padding:9px 12px;border-radius:9px;margin-top:6px}
.msg.ok{color:var(--good);background:color-mix(in srgb,var(--good) 14%,transparent)}
.msg.err{color:var(--crit);background:color-mix(in srgb,var(--crit) 14%,transparent)}
.fleet-grid{display:grid;grid-template-columns:auto repeat(6,1fr);gap:2px;font-size:11.5px;margin-top:6px}
.fleet-grid .cell{padding:6px 8px;background:var(--panel2);border-radius:5px;text-align:center}
.fleet-grid .svc{text-align:left;font-weight:600;text-transform:capitalize;background:transparent}
.fleet-grid .hd{color:var(--muted);font-size:9.5px;letter-spacing:.06em;text-transform:uppercase;background:transparent;padding-bottom:2px}
.fleet-grid .cell.z{color:var(--faint)}
.fleet-grid .cell.pos{color:var(--ink);font-weight:600}
.fleet-grid .cell.bad{color:var(--crit);font-weight:600}

/* empty / loading */
.empty{padding:44px 20px;text-align:center;color:var(--muted);border:1px dashed var(--line2);border-radius:var(--r)}
.empty b{display:block;color:var(--ink);font-family:"Fraunces",Georgia,serif;font-size:18px;margin-bottom:6px}
.skel{color:var(--faint);padding:30px;text-align:center}
.close{margin-left:auto;background:transparent;border:none;color:var(--muted);font-size:20px;line-height:1}

@media (max-width:1080px){ .kpis{grid-template-columns:repeat(4,1fr)} }
@media (max-width:860px){
  main{grid-template-columns:1fr} .side{position:static} .clist{max-height:none;flex-direction:row;overflow:auto}
  .camp{min-width:230px} .lead{grid-template-columns:22px 1fr;gap:10px} .lead .opp,.lead .fit{display:none} .chips{justify-content:flex-start}
}
@media (prefers-reduced-motion:reduce){*{transition:none!important;animation:none!important}}
</style>
</head>
<body>
<header>
  <div class="brand"><b>HiLeadDiscovery</b><span>Ops Console</span></div>
  <div class="grow"></div>
  <button class="tbtn ghost" id="notifBtn" title="System alerts & rate limit center">🔔 Alerts <span id="notifBadge" style="background:var(--warm);color:#000;padding:2px 6px;border-radius:10px;font-size:11px;margin-left:4px;display:none;">0</span></button>
  <button class="tbtn ghost" id="fleetBtn" title="Fleet health">Fleet</button>
  <button class="tbtn ghost" id="schedBtn" title="Scheduled campaigns">Schedules</button>
  <button class="tbtn ghost" id="themeBtn" title="Toggle theme">Theme</button>
  <button class="tbtn ghost" id="outBtn" title="Forget access key">Sign out</button>
  <button class="tbtn primary" id="newBtn">+ New campaign</button>
</header>

<section class="kpis" id="kpis"></section>

<main>
  <aside class="side">
    <h2>Campaigns</h2>
    <div class="clist" id="clist"><div class="skel">Loading…</div></div>
  </aside>
  <section class="board">
    <div class="bhead"><div class="ttl" id="boardTitle">Leads</div><div class="grow"></div><div id="boardMeta" class="cg" style="color:var(--muted);font-size:12px"></div><button class="tbtn" id="schedNowBtn" style="display:none" title="Schedule this campaign to run on a cadence">Schedule…</button><button class="tbtn" id="runNowBtn" style="display:none" title="Launch a fresh campaign with this configuration">Run now</button><button class="tbtn ghost" id="arcCampBtn" style="display:none;color:var(--crit);border-color:color-mix(in srgb,var(--crit) 45%,transparent);" title="Soft-archive this campaign and cascade to all leads, evidence, work items, and reports">&#128230; Archive Campaign</button></div>
    <div id="arcBanner" style="display:none;align-items:center;gap:10px;background:rgba(239,68,68,0.08);border:1px dashed rgba(239,68,68,0.4);border-radius:8px;padding:10px 14px;color:var(--crit);margin-bottom:14px;font-size:13px;"><span style="font-size:16px;">&#128230;</span> <span><b>Archived Campaign (Read Only):</b> This campaign and all its leads and evidence are soft-archived. Fresh campaign runs will ignore this evidence and re-collect live data from web/search providers.</span></div>
    <div class="rows" id="rows"><div class="skel">Select a campaign.</div></div>
  </section>
</main>

<script>
(function(){
  "use strict";
  var KEY_STORE="lgk";
  var state={ key:null, campaigns:[], current:null, selected:null };
  // n8n serves webhook HTML sandboxed (CSP: sandbox, no allow-same-origin) -> localStorage throws.
  // Safe shim: persist when available, fall back to in-memory (key re-prompts each visit).
  var mem={};
  function lsGet(k){ try{ return window.localStorage["getItem"](k); }catch(e){ return (k in mem)?mem[k]:null; } }
  function lsSet(k,v){ try{ window.localStorage["setItem"](k,v); }catch(e){ mem[k]=v; } }
  function lsDel(k){ try{ window.localStorage["removeItem"](k); }catch(e){ delete mem[k]; } }

  function $(id){ return document.getElementById(id); }
  function esc(s){ s=(s==null)?"":String(s); return s.split("&").join("&amp;").split("<").join("&lt;").split(">").join("&gt;").split('"').join("&quot;"); }
  function num(v){ if(v==null||v==="") return null; var n=Number(v); return isFinite(n)?n:null; }
  // Header values must be Latin-1; a pasted key can carry zero-width/smart chars. Keep printable ASCII only.
  function ascii(s){ s=(s==null)?"":String(s); var o=""; for(var i=0;i<s.length;i++){ var c=s.charCodeAt(i); if(c>32&&c<127) o+=s.charAt(i); } return o; }
  function heat(c){ return (c==="hot"||c==="warm"||c==="cold")?c:"dq"; }
  function fmtDate(s){ if(!s) return "—"; try{ var d=new Date(s); return d.toLocaleDateString(undefined,{month:"short",day:"numeric"}); }catch(e){ return "—"; } }
  function money(n){ n=Number(n)||0; return "$"+n.toFixed(n<100?2:0); }

  // ----- access key gate -----
  function gate(errText){
    var wrap=document.createElement("div"); wrap.className="overlay"; wrap.id="gate";
    var pt=errText?('<div class="msg err">'+esc(errText)+'</div>'):"";
    wrap.innerHTML='<div class="sheet" style="max-width:420px"><h3>Enter access key</h3><p class="hint">This console reads live fleet data. Paste your intake key to continue — it stays in this browser only.</p><div class="field"><label>Access key</label><input id="gkey" type="password" placeholder="lgk_…" autocomplete="off"></div>'+pt+'<div class="rowbtns"><button class="tbtn primary" id="gok">Unlock</button></div></div>';
    document.body.appendChild(wrap);
    var inp=$("gkey"); inp.focus();
    function submit(){ var v=ascii(inp.value); if(!v) return; lsSet(KEY_STORE,v); state.key=v; wrap.remove(); boot(); }
    $("gok").onclick=submit;
    inp.onkeydown=function(e){ if(e.key==="Enter") submit(); };
  }

  function api(path){
    var sep=(path.indexOf("?")>=0)?"&":"?";
    var url=path+sep+"_t="+Date.now();
    return fetch(url,{ headers:{ "x-leadgen-key": ascii(state.key) }, cache:"no-store" }).then(function(r){
      if(r.status===401||r.status===403){ var e=new Error("unauthorized"); e.code=401; throw e; }
      if(!r.ok){ throw new Error("HTTP "+r.status); }
      return r.json();
    });
  }

  // ----- KPIs -----
  function renderKpis(d){
    var lk=d.leads_kpis||{}, ck=d.kpis||{};
    var items=[
      {n:ck.campaigns||0,l:"Campaigns"},
      {n:ck.active||0,l:"Active"},
      {n:lk.total||0,l:"Leads"},
      {n:lk.hot||0,l:"Hot",c:"heat-hot"},
      {n:lk.warm||0,l:"Warm",c:"heat-warm"},
      {n:lk.cold||0,l:"Cold",c:"heat-cold"},
      {n:lk.dq||0,l:"Disqualified",c:"heat-dq"},
      {n:d.stuck||0,l:"Stuck items",c:(d.stuck>0?"alert":"")}
    ];
    var h=""; for(var i=0;i<items.length;i++){ var it=items[i];
      h+='<div class="kpi '+(it.c||"")+'"><span class="rail"></span><div class="n mono">'+it.n+'</div><div class="l">'+it.l+'</div></div>'; }
    $("kpis").innerHTML=h;
  }

  // ----- campaigns rail -----
  function statusPill(s){
    var cls="st-idle", t=s||"—";
    if(s==="complete") cls="st-complete";
    else if(s==="discovering"||s==="analyzing"||s==="finalizing") cls="st-run";
    else if(s==="awaiting_approval") cls="st-wait";
    else if(s==="failed"||s==="canceled") cls="st-fail";
    else if(s==="archived") cls="st-archived";
    return '<span class="pill '+cls+'">'+esc(t)+'</span>';
  }
  function geoText(g,t){ if(!g) return t||""; if(g.zip) return g.zip; if(g.city) return g.city; if(g.type) return g.type; return t||""; }
  function renderCampaigns(list){
    var box=$("clist");
    if(!list||!list.length){ box.innerHTML='<div class="empty"><b>No campaigns yet</b>Launch one with “+ New campaign”.</div>'; $("rows").innerHTML=""; $("boardTitle").textContent="Leads"; return; }
    var h="";
    for(var i=0;i<list.length;i++){ var c=list[i];
      var leads=Number(c.leads)||0;
      var isArc=(c.status==="archived"||c.archived_at!=null);
      var seg=function(k){ var v=Number(c[k])||0; var p=leads>0?(v/leads*100):0; return v>0?('<i class="'+k+'" style="width:'+p+'%"></i>'):""; };
      var stack='<div class="stack">'+seg("hot")+seg("warm")+seg("cold")+seg("dq")+'</div>';
      h+='<button class="camp'+(isArc?' is-archived':'')+'" data-id="'+esc(c.id)+'"><div class="top"><span class="ct">'+esc(c.business_type||"—")+'</span>'+statusPill(isArc?'archived':c.status)+'</div>'+
         '<div class="cg">'+esc(geoText(c.geo_original,c.geo_type))+'</div>'+
         '<div style="font-family:monospace;font-size:10px;color:var(--faint);margin:2px 0 4px 0;user-select:all;word-break:break-all;" title="Campaign ID">id: '+esc(c.id)+'</div>'+stack+
         '<div class="meta"><span>'+leads+' leads · '+(Number(c.hot)||0)+'H '+(Number(c.warm)||0)+'W</span><span>'+money(c.spent_usd)+' · '+fmtDate(c.created_at)+'</span></div></button>';
    }
    box.innerHTML=h;
    var btns=box.querySelectorAll(".camp");
    for(var j=0;j<btns.length;j++){ btns[j].onclick=function(){ selectCampaign(this.getAttribute("data-id")); }; }
  }

  function selectCampaign(id){
    state.current=id;
    var btns=document.querySelectorAll(".camp");
    for(var i=0;i<btns.length;i++){ btns[i].classList.toggle("sel", btns[i].getAttribute("data-id")===id); }
    var c=null; for(var k=0;k<state.campaigns.length;k++){ if(state.campaigns[k].id===id) c=state.campaigns[k]; }
    var isArc=c&&(c.status==="archived"||c.archived_at!=null);
    $("runNowBtn").style.display=(c&&!isArc)?"inline-flex":"none";
    $("schedNowBtn").style.display=(c&&!isArc)?"inline-flex":"none";
    $("arcCampBtn").style.display=(c&&!isArc)?"inline-flex":"none";
    if($("arcBanner")) $("arcBanner").style.display=isArc?"flex":"none";
    $("boardTitle").innerHTML=c?(esc(c.business_type||"Leads")+(isArc?' <span class="pill st-archived" style="color:var(--crit);border-color:rgba(239,68,68,0.5);background:rgba(239,68,68,0.12);font-weight:700;">&#128230; ARCHIVED</span>':'')):"Leads";
    $("boardMeta").textContent=c?(geoText(c.geo_original,c.geo_type)+" · "+(isArc?"archived (read-only)":(c.status||""))):"";
    var rowsEl=$("rows");
    if(rowsEl){ if(isArc) rowsEl.classList.add("is-archived"); else rowsEl.classList.remove("is-archived"); }
    rowsEl.innerHTML='<div class="skel">Loading leads…</div>';
    api("leadgen-console-leads?campaign="+encodeURIComponent(id)).then(renderBoard).catch(fail);
  }

  function archiveCampaign(){
    var cur=state.current; if(!cur) return;
    var camp=null; for(var k=0;k<state.campaigns.length;k++){ if(state.campaigns[k].id===cur) camp=state.campaigns[k]; }
    var label=camp?((camp.business_type||"Campaign")+" ("+geoText(camp.geo_original,camp.geo_type)+")"):cur;
    if(!confirm("Soft-archive entire campaign '"+label+"' and cascade soft-archive to all leads, evidence, work items, and reports?\n\n(Archived evidence will be ignored by future runs, prompting fresh re-collection from live providers)")) return;
    fetch("leadgen-console-action",{ method:"POST", headers:{ "x-leadgen-key":ascii(state.key), "content-type":"application/json" }, body:JSON.stringify({ action:"archive_campaign", campaign_id:cur }) })
      .then(function(r){ return r.json(); })
      .then(function(res){
        if(res && res.ok){ toast("Campaign archived! All findings soft-archived."); boot(cur); }
        else{ alert((res && res.error) || "Could not archive campaign."); }
      })
      .catch(fail);
  }

  // ----- lead board -----
  function unmemorable(domain){
    if(!domain) return false; var d=String(domain).toLowerCase();
    var s=d.indexOf("//"); if(s>=0) d=d.slice(s+2); if(d.indexOf("www.")===0) d=d.slice(4);
    d=d.split("/")[0].split("?")[0]; var dot=d.lastIndexOf("."); if(dot>0) d=d.slice(0,dot);
    var alpha=0, hd=false; for(var i=0;i<d.length;i++){ var ch=d[i]; if(ch>="a"&&ch<="z") alpha++; if(ch==="-"||(ch>="0"&&ch<="9")) hd=true; }
    return alpha>=20 || hd;
  }
  function fitStrip(l){
    var vals=[{k:"web_seo",c:"W",v:num(l.web_seo)},{k:"voice_ai",c:"V",v:num(l.voice_ai)},{k:"ads_video",c:"A",v:num(l.ads_video)},{k:"consulting",c:"C",v:num(l.consulting)}];
    var best=l.best_angle;
    var h='<div class="fit">';
    for(var i=0;i<vals.length;i++){ var f=vals[i]; var v=f.v==null?0:Math.max(0,Math.min(100,f.v));
      var isBest=(best===f.k);
      h+='<div class="col'+(isBest?" best":"")+'" title="'+f.c+" "+(f.v==null?"n/a":Math.round(f.v))+'"><div class="track"><div class="seg" style="height:'+v+'%"></div></div><div class="cl">'+f.c+'</div></div>';
    }
    return h+'</div>';
  }
  function chips(l){
    var s=l.signals||{}, out=[];
    var rating=num(s.rating), rv=num(s.review_volume);
    if(rating!=null){ out.push('<span class="chip" title="Google rating · reviews">&#9733; '+rating.toFixed(1)+(rv!=null?' · '+rv:'')+'</span>'); }
    var sp=num(s.social_platform_count);
    if(sp!=null){
      var cls=(s.social_inactive_90d===true||s.social_inactive_90d==="true")?"chip gold":"chip";
      var extra=""; var fol=num(s.social_followers); if(fol!=null) extra=' · '+(fol>=1000?(Math.round(fol/100)/10)+'k':fol)+' foll';
      var lp=num(s.social_last_post_days); if(lp!=null) extra+=' · '+lp+'d';
      out.push('<span class="'+cls+'" title="Social platforms present">&#9678; '+sp+' social'+extra+'</span>');
    }
    var pa=s.phone_assistant_type;
    if(pa==="ai_assistant"||pa==="ai_receptionist"){ out.push('<span class="chip ember" title="Phone probe: AI receptionist detected">AI phone</span>'); }
    else if(pa==="human"){ out.push('<span class="chip mut" title="Phone probe: human answered">Human phone</span>'); }
    if(s.phone_unanswered===true||s.phone_unanswered==="true"){ out.push('<span class="chip gold" title="Phone probe: unanswered">No answer</span>'); }
    var px=num(s.pixel_count); if(px!=null&&px>0){ out.push('<span class="chip" title="Marketing pixels on site">px '+px+'</span>'); }
    if(s.chat_widget_present===true){ out.push('<span class="chip leaf" title="Chat widget on site">chat</span>'); }
    if(s.booking_widget_present===true){ out.push('<span class="chip leaf" title="Booking widget on site">booking</span>'); }
    if(unmemorable(l.domain)){ out.push('<span class="chip gold" title="Long / hard-to-recall domain">long domain</span>'); }
    if(l.is_cached===true){ out.push('<span class="chip mut" title="Evidence reused from a prior active campaign">&#8635; cached</span>'); }
    var mp=s.marketing_pixels||{}; var adDefs=[["meta_pixel","Meta"],["google_ads","Google"],["bing_ads","Bing"],["yelp_pixel","Yelp"],["nextdoor_pixel","Nextdoor"],["tiktok_pixel","TikTok"],["linkedin_insight","LinkedIn"],["twitter_ads","X"]]; var adOn=[]; for(var ai=0;ai<adDefs.length;ai++){ if(mp[adDefs[ai][0]]===true) adOn.push(adDefs[ai][1]); }
    var asx=s.ad_status||null; var adConf=[]; if(asx&&asx.summary){ if(asx.summary.meta==="CONFIRMED")adConf.push("Meta"); if(asx.summary.google==="CONFIRMED")adConf.push("Google"); if(asx.summary.bing==="CONFIRMED")adConf.push("Bing"); if(asx.summary.yelp==="CONFIRMED")adConf.push("Yelp"); if(asx.summary.nextdoor==="CONFIRMED")adConf.push("Nextdoor"); }
    if(adConf.length){ out.push('<span class="chip ember" title="Confirmed active ads (live verification)">ads &#10003; '+esc(adConf.join(", "))+'</span>'); }
    else if(adOn.length){ out.push('<span class="chip gold" title="Ad pixels detected — likely running ads">ads: '+esc(adOn.join(", "))+'</span>'); }
    else if(s.marketing_pixels||asx){ out.push('<span class="chip leaf" title="No active ads / no ad pixels — consult opportunity">no ads</span>'); }
    var comp=s.competitor_set||null;
    if(comp && comp.best){
      var best=comp.best||{};
      var bestName=best.name?String(best.name):"Top competitor";
      var myReviews=rv!=null?rv:num(comp.target&&comp.target.reviews);
      var theirReviews=num(best.reviews);
      var gap=(theirReviews!=null&&myReviews!=null)?(theirReviews-myReviews):null;
      var confirmed=(best.ads&&Array.isArray(best.ads.confirmed))?best.ads.confirmed:[];
      var compLabel='vs '+bestName;
      if(gap!=null && gap>0) compLabel+=' · +'+gap+' rev';
      if(confirmed.length) compLabel+=' · ads';
      out.push('<span class="chip mut" title="Best nearby competitor snapshot from competitor_set evidence">'+esc(compLabel)+'</span>');
    }
    if(l.report_url){ out.push('<a class="chip rep" href="'+esc(l.report_url)+'" target="_blank" rel="noopener" title="Open the generated report">Report &#8599;</a>'); }
    out.push('<button class="chip act-log" data-lead="'+esc(l.lead_id)+'" title="Inspect phone transcripts, LLM inputs, Bing ads, and JSON evidence ledger">{ } Debug Logs</button>');
    out.push('<button class="chip act" data-lead="'+esc(l.lead_id)+'" title="Force a fresh deep analysis: website, reviews, social, phone, ads and competitors, then re-score">&#8635; Re-analyze</button>');
    if(l.archived_at){
      out.push('<span class="chip mut" style="color:var(--dq);border-color:var(--dq);" title="Lead is soft-archived">&#128230; Archived</span>');
    }else{
      out.push('<button class="chip act-arc" data-lead="'+esc(l.lead_id)+'" style="color:var(--dq);border-color:var(--dq);" title="Soft-archive this lead and its evidence">&#128230; Archive</button>');
    }
    return '<div class="chips">'+out.join("")+'</div>';
  }
  function contactSub(l){
    var bits=[];
    if(l.domain){ var dd=String(l.domain); var u=(dd.indexOf("://")>=0)?dd:("https://"+dd); bits.push('<a href="'+esc(u)+'" target="_blank" rel="noopener">'+esc(l.domain)+'</a>'); }
    if(l.phone){ bits.push('<a href="tel:'+esc(l.phone)+'">'+esc(l.phone)+'</a>'); }
    if(l.address){ bits.push(esc(String(l.address).split(",")[0])); }
    return bits.join('<span style="color:var(--faint)">·</span>');
  }
  function archiveLead(lid){
    if(!confirm("Soft-archive this lead and its evidence? (Archived evidence will be ignored by future campaigns, prompting fresh re-collection from live providers)")) return;
    fetch("leadgen-console-action",{ method:"POST", headers:{ "x-leadgen-key":ascii(state.key), "content-type":"application/json" }, body:JSON.stringify({ action:"archive_lead", lead_id:lid }) })
      .then(function(r){ return r.json(); })
      .then(function(res){
        if(res && res.ok){ toast("Lead archived successfully! Fresh campaigns will re-collect evidence."); boot(state.current); }
        else{ alert((res && res.error) || "Could not archive lead."); }
      })
      .catch(fail);
  }
  function renderBoard(leads){
    var box=$("rows");
    if(!leads||!leads.length){ box.innerHTML='<div class="empty"><b>No leads scored yet</b>The fleet is still working this campaign, or nothing cleared discovery.</div>'; return; }
    var h="";
    for(var i=0;i<leads.length;i++){ var l=leads[i];
      var hc=heat(l.classification);
      var opp=num(l.opportunity);
      var oppv=opp==null?0:Math.max(0,Math.min(100,opp));
      var color="var(--"+hc+")";
      var tag=l.hot_candidate&&l.classification!=="hot"?'<span class="htag warm" title="Hot candidate awaiting critic">candidate</span>':"";
      var arcTag=l.archived_at?'<span class="htag dq" title="Lead is soft-archived">&#128230; archived</span>':"";
      h+='<div class="lead" style="'+(l.archived_at?'opacity:0.75;':'')+'">'+
         '<div class="rank mono">'+(i+1)+'</div>'+
         '<div class="who"><div class="nm"><span class="heat '+hc+'"></span>'+esc(l.name||"—")+' <span class="htag '+hc+'">'+esc(l.classification||"?")+'</span>'+tag+arcTag+'</div><div class="sub">'+contactSub(l)+'</div></div>'+
         '<div class="opp"><div class="val mono" style="color:'+color+'">'+(opp==null?"—":Math.round(opp))+'</div><div class="bar"><div class="fill" style="width:'+oppv+'%;background:'+color+'"></div><div class="tick"></div></div><small>opportunity</small></div>'+
         '<div>'+fitStrip(l)+'</div>'+
         chips(l)+
         '</div>';
    }
    box.innerHTML=h;
    var leadMap={}; for(var m=0;m<leads.length;m++){ leadMap[leads[m].lead_id]=leads[m]; }
    var rbs=box.querySelectorAll(".act");
    for(var q=0;q<rbs.length;q++){ rbs[q].onclick=function(){ reanalyze(this.getAttribute("data-lead"), this); }; }
    var lbs=box.querySelectorAll(".act-log");
    for(var p=0;p<lbs.length;p++){ lbs[p].onclick=function(){ var lid=this.getAttribute("data-lead"); if(leadMap[lid]) openDebugLogsModal(leadMap[lid]); }; }
    var abs=box.querySelectorAll(".act-arc");
    for(var a=0;a<abs.length;a++){ abs[a].onclick=function(){ archiveLead(this.getAttribute("data-lead")); }; }
  }

  function openDebugLogsModal(l){
    var s=l.signals||{}, ev=l.evidence_ledger||[], runs=l.service_runs||[];
    var plog=s.phone_probe_log||{};
    var phoneEv=ev.filter(function(e){ return e.source_provider==='phone_probe'||(e.feature_key&&e.feature_key.indexOf('phone')>=0); });
    var phoneRuns=runs.filter(function(r){ return r.service==='phone_probe'; });
    var phoneSummary={
      phone_e164: l.phone||plog.phone_e164||null,
      answered_by: s.phone_probe_answered_by||plog.answered_by||'unknown',
      assistant_type: s.phone_assistant_type||plog.phone_assistant_type||'unclear',
      unanswered: s.phone_unanswered||false,
      transcript: plog.words_spoken_transcript||plog.transcript||(plog.llm_raw_response&&(plog.llm_raw_response.words_spoken||plog.llm_raw_response.transcript))||"No call transcript recorded yet (phone probe not executed or call unanswered)",
      twilio_call_sid: plog.twilio_call_sid||null,
      llm_audio_prompt: plog.llm_audio_prompt||null,
      llm_raw_response: plog.llm_raw_response||null,
      probe_runs: phoneRuns,
      evidence_items: phoneEv
    };
    var adStatus=s.ad_status||{}, adPixels=s.marketing_pixels||{};
    var adsSummary={
      bing_ads:{
        pixel_on_site: !!adPixels.bing_ads,
        confirmed_search_ads: (adStatus.summary&&adStatus.summary.bing)||"NONE"
      },
      meta_ads: (adStatus.summary&&adStatus.summary.meta)||(adPixels.meta_pixel?"LIKELY":"NONE"),
      google_ads: (adStatus.summary&&adStatus.summary.google)||(adPixels.google_ads?"LIKELY":"NONE"),
      yelp_ads: (adStatus.summary&&adStatus.summary.yelp)||(adPixels.yelp_pixel?"LIKELY":"NONE"),
      nextdoor_ads: adPixels.nextdoor_pixel?"LIKELY":"NONE",
      all_live_ad_urls: (adStatus.evidence_ledger&&adStatus.evidence_ledger.live_ad_urls)||[]
    };
    var llmSummary={
      vision_design: s.design_findings||null,
      review_complaints: s.complaint_themes||null,
      report_generator:{
        report_url: l.report_url||null,
        summary: l.report_summary||null,
        prompt_version: l.prompt_version||null,
        model_version: l.model_version||null,
        validation: l.report_validation||null
      }
    };
    var wrap=document.createElement("div"); wrap.className="overlay";
    wrap.innerHTML='<div class="sheet" style="max-width:820px;max-height:85vh;display:flex;flex-direction:column">'+
      '<div style="display:flex;align-items:center"><h3 style="margin:0">Debug Logs: '+esc(l.name||"Lead")+'</h3><button class="close" title="Close">&times;</button></div>'+
      '<p class="hint">Technical inspection &amp; JSON ledger for visual debugging.</p>'+
      '<div style="display:flex;gap:8px;margin-bottom:12px;border-bottom:1px solid var(--line);padding-bottom:8px">'+
        '<button class="tbtn segbtn on" id="tab_bing">Bing &amp; Ads</button>'+
        '<button class="tbtn segbtn" id="tab_phone">Phone Probe Log</button>'+
        '<button class="tbtn segbtn" id="tab_llm">LLM Feeds</button>'+
        '<button class="tbtn segbtn" id="tab_json">Raw JSON Ledger</button>'+
      '</div>'+
      '<div id="tab_body" style="flex:1;overflow:auto;background:var(--bg);padding:14px;border-radius:9px;font-family:\'IBM Plex Mono\',monospace;font-size:12px;white-space:pre-wrap;word-break:break-all"></div>'+
      '</div>';
    document.body.appendChild(wrap);
    var body=wrap.querySelector("#tab_body");
    function setTab(name, data){
      var tabs=["tab_bing","tab_phone","tab_llm","tab_json"];
      for(var i=0;i<tabs.length;i++){
        var t=wrap.querySelector("#"+tabs[i]);
        if(t) t.classList.toggle("on", tabs[i]===("tab_"+name));
      }
      body.textContent=JSON.stringify(data, null, 2);
    }
    wrap.querySelector("#tab_bing").onclick=function(){ setTab("bing", adsSummary); };
    wrap.querySelector("#tab_phone").onclick=function(){ setTab("phone", phoneSummary); };
    wrap.querySelector("#tab_llm").onclick=function(){ setTab("llm", llmSummary); };
    wrap.querySelector("#tab_json").onclick=function(){ setTab("json", { signals:s, evidence_ledger:ev, service_runs:runs }); };
    setTab("bing", adsSummary);
    var cl=function(){ wrap.remove(); };
    wrap.querySelector(".close").onclick=cl;
    wrap.onclick=function(e){ if(e.target===wrap) cl(); };
  }

  // ----- fleet drawer -----
  function fleet(){
    api("leadgen-console-data").then(function(d){
      var states=["pending","running","done","blocked","failed_retryable","skipped_prerequisite"];
      var svcs={}; var f=d.fleet||[];
      for(var i=0;i<f.length;i++){ var r=f[i]; if(!svcs[r.service]) svcs[r.service]={}; svcs[r.service][r.state]=Number(r.n)||0; }
      var names=Object.keys(svcs).sort();
      var g='<div class="fleet-grid"><div class="hd svc">Service</div>';
      for(var s=0;s<states.length;s++){ g+='<div class="hd">'+states[s].replace("_prerequisite","").replace("_retryable"," retry").replace("skipped","skip")+'</div>'; }
      for(var n=0;n<names.length;n++){ var sv=names[n]; g+='<div class="cell svc">'+esc(sv)+'</div>';
        for(var t=0;t<states.length;t++){ var v=svcs[sv][states[t]]||0; var cc=v===0?"z":(states[t]==="failed_retryable"&&v>0?"bad":"pos"); g+='<div class="cell '+cc+'">'+v+'</div>'; }
      }
      g+='</div>';
      var wrap=document.createElement("div"); wrap.className="overlay";
      wrap.innerHTML='<div class="sheet"><div style="display:flex;align-items:center"><h3 style="margin:0">Fleet health</h3><button class="close" title="Close">&times;</button></div><p class="hint">Work items by service and state (prod). '+(d.stuck>0?('<b style="color:var(--crit)">'+d.stuck+' stuck</b> — leased-past-expiry, retry-stalled, or blocked &gt;24h.'):'No stuck items.')+'</p>'+g+'</div>';
      document.body.appendChild(wrap);
      var cl=function(){ wrap.remove(); }; wrap.querySelector(".close").onclick=cl;
      wrap.onclick=function(e){ if(e.target===wrap) cl(); };
    }).catch(fail);
  }

  // ----- new campaign -----
  function newCampaign(){
    var wrap=document.createElement("div"); wrap.className="overlay";
    wrap.innerHTML='<div class="sheet"><div style="display:flex;align-items:center"><h3 style="margin:0">New campaign</h3><button class="close" title="Close">&times;</button></div>'+
      '<div style="display:flex;gap:6px;margin:10px 0 14px"><button class="tbtn segbtn on" id="m_area">Search an area</button><button class="tbtn segbtn" id="m_target">Analyze one business</button></div>'+
      '<div class="field"><label>Business type</label><input id="f_bt" placeholder="e.g. med spa, HVAC, dentist"></div>'+
      '<div id="grp_area">'+
        '<div class="grid2"><div class="field"><label>Location type</label><select id="f_gt"><option value="zip">ZIP code</option><option value="city_radius">City + radius</option></select></div>'+
        '<div class="field"><label id="f_gl">ZIP code</label><input id="f_gv" placeholder="78704"></div></div>'+
        '<div class="grid2"><div class="field"><label>Radius (miles)</label><input id="f_rad" type="number" value="8" min="1"></div>'+
        '<div class="field"><label>Volume cap</label><input id="f_vol" type="number" value="25" min="1" max="300"></div></div>'+
      '</div>'+
      '<div id="grp_target" style="display:none">'+
        '<div class="field"><label>Business name</label><input id="t_name" placeholder="e.g. Skin Envy"></div>'+
        '<div class="grid2"><div class="field"><label>City (optional)</label><input id="t_city" placeholder="Austin, TX"></div>'+
        '<div class="field"><label>Website (optional)</label><input id="t_web" placeholder="https://…"></div></div>'+
        '<p class="hint" style="margin:-4px 0 12px">Enter a business name (city helps disambiguate) or a website URL. Analyzes just that one business.</p>'+
      '</div>'+
      '<div class="grid2"><div class="field"><label>Depth</label><select id="f_depth"><option>standard</option><option>quick</option><option>deep</option></select></div>'+
      '<div class="field"><label>Budget (USD)</label><input id="f_bud" type="number" value="25" min="1"></div></div>'+
      '<div class="field" style="flex-direction:row;align-items:center;gap:8px"><input id="f_dry" type="checkbox" style="width:auto"><label style="text-transform:none;letter-spacing:0;font-size:13px">Dry run (note: not fully isolated yet)</label></div>'+
      '<div id="f_msg"></div>'+
      '<div class="rowbtns"><button class="tbtn ghost" id="f_cancel">Cancel</button><button class="tbtn primary" id="f_go">Launch campaign</button></div></div>';
    document.body.appendChild(wrap);
    var cl=function(){ wrap.remove(); };
    wrap.querySelector(".close").onclick=cl; $("f_cancel").onclick=cl;
    wrap.onclick=function(e){ if(e.target===wrap) cl(); };
    var mode="area";
    function setMode(m){ mode=m; $("m_area").classList.toggle("on",m==="area"); $("m_target").classList.toggle("on",m==="target"); $("grp_area").style.display=(m==="area")?"block":"none"; $("grp_target").style.display=(m==="target")?"block":"none"; }
    $("m_area").onclick=function(){ setMode("area"); }; $("m_target").onclick=function(){ setMode("target"); };
    $("f_gt").onchange=function(){ var z=this.value==="zip"; $("f_gl").textContent=z?"ZIP code":"City"; $("f_gv").placeholder=z?"78704":"Austin, TX"; };
    $("f_go").onclick=function(){
      var bt=$("f_bt").value.trim(); var msg=$("f_msg");
      if(!bt){ msg.innerHTML='<div class="msg err">Business type is required.</div>'; return; }
      var body={ request_id:"console-"+Date.now(), business_type:bt, depth:$("f_depth").value, budget:{ amount:Number($("f_bud").value)||25, currency:"USD" }, dry_run:$("f_dry").checked };
      if(mode==="target"){
        var nm=$("t_name").value.trim(), ws=$("t_web").value.trim(), ct=$("t_city").value.trim();
        if(!nm && !ws){ msg.innerHTML='<div class="msg err">Enter a business name or a website.</div>'; return; }
        var target={}; if(nm) target.name=nm; if(ct) target.city=ct; if(ws) target.website=ws;
        body.target=target; body.volume_cap=1;
      } else {
        var gv=$("f_gv").value.trim(); var gt=$("f_gt").value;
        if(!gv){ msg.innerHTML='<div class="msg err">Location is required.</div>'; return; }
        var geo={ type:gt, radius_m: Math.round((Number($("f_rad").value)||8)*1609) };
        if(gt==="zip") geo.zip=gv; else geo.city=gv;
        body.geo=geo; body.volume_cap=Math.round(Number($("f_vol").value)||25);
      }
      this.disabled=true; this.textContent="Launching…";
      var self=this;
      fetch("leadgen-intake-api",{ method:"POST", headers:{ "x-leadgen-key":ascii(state.key), "content-type":"application/json" }, body:JSON.stringify(body) })
        .then(function(r){ return r.json(); })
        .then(function(res){
          if(res && res.ok){
            msg.innerHTML='<div class="msg ok">Campaign '+(res.creation_status||"created")+'. Refreshing…</div>';
            var newId=res.campaign_id;
            setTimeout(function(){ cl(); boot(newId); }, 800);
          } else{ self.disabled=false; self.textContent="Launch campaign"; msg.innerHTML='<div class="msg err">'+esc((res&&res.error)||"Could not create campaign.")+'</div>'; }
        })
        .catch(function(){ self.disabled=false; self.textContent="Launch campaign"; msg.innerHTML='<div class="msg err">Network error — check the connection and try again.</div>'; });
    };
    $("f_bt").focus();
  }

  // ----- run now: clone this campaign's config into a fresh campaign via the intake API -----
  function runNow(){
    var c=state.selected; if(!c) return;
    if(!window.confirm("Launch a fresh campaign for \""+(c.business_type||"")+"\" in "+geoText(c.geo_original,c.geo_type)+"? This re-runs discovery and spends API budget.")) return;
    var b=$("runNowBtn"); b.disabled=true; b.textContent="Launching…";
    var body={ request_id:"rerun-"+String(c.id).slice(0,8)+"-"+Date.now(), business_type:c.business_type, geo:(c.geo_original||{}), depth:(c.depth||"standard"), volume_cap:Math.round(Number(c.volume_cap)||25), budget:{ amount:Number(c.budget_cap_usd)||25, currency:"USD" } };
    fetch("leadgen-intake-api",{ method:"POST", headers:{ "x-leadgen-key":ascii(state.key), "content-type":"application/json" }, body:JSON.stringify(body) })
      .then(function(r){ return r.json(); })
      .then(function(res){
        b.disabled=false; b.textContent="Run now";
        if(res&&res.ok){ toast("New campaign launched!"); boot(res.campaign_id); }
        else { window.alert("Could not launch: "+((res&&res.error)||"error")); }
      })
      .catch(function(){ b.disabled=false; b.textContent="Run now"; window.alert("Network error — try again."); });
  }

  // ----- re-analyze one lead: force a fresh scrape + re-score via the action endpoint -----
  function reanalyze(leadId, btn){
    if(!leadId) return;
    if(!window.confirm("Re-analyze this lead now? Rechecks website, reviews, social, phone, ads and competitors, then re-scores. This spends API budget.")) return;
    if(btn){ btn.disabled=true; btn.textContent="Re-analyzing…"; }
    fetch("leadgen-console-action",{ method:"POST", headers:{ "x-leadgen-key":ascii(state.key), "content-type":"application/json" }, body:JSON.stringify({ action:"reanalyze", lead_id:leadId }) })
      .then(function(r){ return r.json(); })
      .then(function(res){
        if(res&&res.ok){ if(btn){ btn.textContent="Queued ✓"; } setTimeout(function(){ if(state.current) selectCampaign(state.current); }, 2000); }
        else { if(btn){ btn.disabled=false; btn.textContent="Re-analyze"; } window.alert("Could not re-analyze: "+((res&&res.error)||"error")); }
      })
      .catch(function(){ if(btn){ btn.disabled=false; btn.textContent="Re-analyze"; } window.alert("Network error — try again."); });
  }

  // ----- schedule a campaign on a cadence -----
  function scheduleModal(){
    var c=state.selected; if(!c) return;
    var wrap=document.createElement("div"); wrap.className="overlay";
    wrap.innerHTML='<div class="sheet"><div style="display:flex;align-items:center"><h3 style="margin:0">Schedule campaign</h3><button class="close" title="Close">&times;</button></div>'+
      '<p class="hint">Re-runs this '+esc(c.business_type||"")+' search on a cadence via the scheduler. Scheduled runs spend API budget.</p>'+
      '<div class="grid2"><div class="field"><label>Cadence</label><select id="s_cad"><option value="weekly">Weekly</option><option value="monthly">Monthly</option><option value="once">Once</option></select></div>'+
      '<div class="field"><label>First run (optional)</label><input id="s_when" type="datetime-local"></div></div>'+
      '<p class="hint" style="margin:-4px 0 12px">Blank starts weekly/monthly from now. For Once, pick a date and time.</p>'+
      '<div id="s_msg"></div>'+
      '<div class="rowbtns"><button class="tbtn ghost" id="s_cancel">Cancel</button><button class="tbtn primary" id="s_go">Create schedule</button></div></div>';
    document.body.appendChild(wrap);
    var cl=function(){ wrap.remove(); };
    wrap.querySelector(".close").onclick=cl; $("s_cancel").onclick=cl; wrap.onclick=function(e){ if(e.target===wrap) cl(); };
    $("s_go").onclick=function(){
      var cad=$("s_cad").value; var when=$("s_when").value; var msg=$("s_msg");
      if(cad==="once" && !when){ msg.innerHTML='<div class="msg err">Pick a date and time for a one-off run.</div>'; return; }
      var body={ action:"schedule", campaign_id:c.id, cadence:cad };
      if(when){ try{ body.next_run_at=new Date(when).toISOString(); }catch(e){} }
      this.disabled=true; this.textContent="Creating…"; var self=this;
      fetch("leadgen-console-action",{ method:"POST", headers:{ "x-leadgen-key":ascii(state.key), "content-type":"application/json" }, body:JSON.stringify(body) })
        .then(function(r){ return r.json(); })
        .then(function(res){ if(res&&res.ok){ msg.innerHTML='<div class="msg ok">Scheduled ('+esc(res.cadence||cad)+'). Next run '+fmtDate(res.next_run_at)+'.</div>'; setTimeout(cl,1400); } else { self.disabled=false; self.textContent="Create schedule"; msg.innerHTML='<div class="msg err">'+esc((res&&res.error)||"Could not schedule.")+'</div>'; } })
        .catch(function(){ self.disabled=false; self.textContent="Create schedule"; msg.innerHTML='<div class="msg err">Network error — try again.</div>'; });
    };
  }
  function schedulesDrawer(){
    api("leadgen-console-data").then(function(d){
      var s=d.schedules||[]; var body="";
      if(!s.length){ body='<div class="empty"><b>No schedules</b>Select a campaign, then click Schedule…</div>'; }
      else { for(var i=0;i<s.length;i++){ var x=s[i];
        body+='<div class="lead" style="grid-template-columns:1fr auto;gap:12px;box-shadow:none">'+
          '<div class="who"><div class="nm">'+esc(x.business_type||x.label||"—")+' <span class="htag '+(x.enabled?"warm":"dq")+'">'+esc(x.cadence)+'</span></div>'+
          '<div class="sub">next '+fmtDate(x.next_run_at)+' · '+(Number(x.run_count)||0)+' runs'+(x.enabled?"":" · paused")+'</div></div>'+
          (x.enabled?('<button class="tbtn ghost sched-pause" data-id="'+esc(x.id)+'">Pause</button>'):"")+
          '</div>'; } }
      var wrap=document.createElement("div"); wrap.className="overlay";
      wrap.innerHTML='<div class="sheet"><div style="display:flex;align-items:center"><h3 style="margin:0">Schedules</h3><button class="close" title="Close">&times;</button></div><p class="hint">Recurring &amp; one-off launches. The scheduler fires due schedules hourly (prod only).</p><div class="rows">'+body+'</div></div>';
      document.body.appendChild(wrap);
      var cl=function(){ wrap.remove(); }; wrap.querySelector(".close").onclick=cl; wrap.onclick=function(e){ if(e.target===wrap) cl(); };
      var pbs=wrap.querySelectorAll(".sched-pause");
      for(var q=0;q<pbs.length;q++){ pbs[q].onclick=function(){ var self=this; self.disabled=true; self.textContent="Pausing…"; fetch("leadgen-console-action",{ method:"POST", headers:{ "x-leadgen-key":ascii(state.key), "content-type":"application/json" }, body:JSON.stringify({ action:"unschedule", schedule_id:this.getAttribute("data-id") }) }).then(function(r){ return r.json(); }).then(function(){ cl(); schedulesDrawer(); }).catch(function(){ self.disabled=false; self.textContent="Pause"; }); }; }
    }).catch(fail);
  }

  function fail(e){
    if(e&&e.code===401){ state.key=null; lsDel(KEY_STORE); gate("That key was rejected. Check it and try again."); return; }
    $("rows").innerHTML='<div class="empty"><b>Could not load data</b>'+esc((e&&e.message)||"Unknown error")+'. Try refreshing.</div>';
  }

  function boot(preferredCampaignId){
    var target=preferredCampaignId||state.current;
    api("leadgen-console-data").then(function(d){
      renderKpis(d);
      state.campaigns=d.campaigns||[];
      renderCampaigns(state.campaigns);
      var keep=target&&state.campaigns.some(function(c){ return c.id===target; });
      var pick=keep?target:(state.campaigns[0]&&state.campaigns[0].id);
      if(pick) selectCampaign(pick);
    }).catch(fail);
  }

  // Automatic background polling every 5 seconds to sync campaigns & active lead board live
  setInterval(function(){
    if(!state.key) return;
    api("leadgen-console-data").then(function(d){
      var oldLen=state.campaigns.length;
      state.campaigns=d.campaigns||[];
      renderKpis(d);
      renderFleet(d);
      renderStuck(d);
      renderCampaigns(state.campaigns);
      if(oldLen>0 && state.campaigns.length>oldLen && state.campaigns[0]){
        selectCampaign(state.campaigns[0].id);
      } else if(state.current){
        api("leadgen-console-leads?campaign="+encodeURIComponent(state.current)).then(renderBoard).catch(function(){});
      }
    }).catch(function(){});
  }, 5000);

  // theme
  function initTheme(){
    var t=lsGet("lg_theme"); if(t) document.documentElement.setAttribute("data-theme",t);
    $("themeBtn").onclick=function(){
      var cur=document.documentElement.getAttribute("data-theme");
      var dark=window.matchMedia&&window.matchMedia("(prefers-color-scheme: dark)").matches;
      var next=cur?(cur==="dark"?"light":"dark"):(dark?"light":"dark");
      document.documentElement.setAttribute("data-theme",next); lsSet("lg_theme",next);
    };
  }

  // wire
  initTheme();
  $("newBtn").onclick=newCampaign;
  $("runNowBtn").onclick=runNow;
  $("schedNowBtn").onclick=scheduleModal;
  $("arcCampBtn").onclick=archiveCampaign;
  $("schedBtn").onclick=schedulesDrawer;
  $("fleetBtn").onclick=fleet;
  $("outBtn").onclick=function(){ lsDel(KEY_STORE); state.key=null; location.reload(); };
  state.key=ascii(lsGet(KEY_STORE));
  if(state.key) boot(); else gate(null);
})();
</script>
</body>
</html>`;

const renderPage = node({ type: 'n8n-nodes-base.code', version: 2, config: { name: 'Render Console HTML', position: [440, 120], parameters: { mode: 'runOnceForAllItems', language: 'javaScript', jsCode: 'return [{ json: { html: ' + JSON.stringify(PAGE) + ' } }];' } }, output: [{ html: '' }] });

const respondPage = node({ type: 'n8n-nodes-base.respondToWebhook', version: 1.5, config: { name: 'Serve Page', position: [700, 120], parameters: { respondWith: 'text', responseBody: expr('={{ $json.html }}'), options: { responseHeaders: { entries: [{ name: 'Content-Type', value: 'text/html; charset=utf-8' }] } } } } });

// ---------- 2) Overview data (JSON) ----------
const hookData = trigger({ type: 'n8n-nodes-base.webhook', version: 2.1, config: { name: 'Data API', position: [200, 340], parameters: { httpMethod: 'GET', path: 'leadgen-console-data', responseMode: 'responseNode' } }, output: [{ headers: {} }] });

const authData = ifElse({ version: 2.2, config: { name: 'Data Authorized?', position: [440, 340], parameters: { conditions: { options: { caseSensitive: true, leftValue: '', typeValidation: 'strict', version: 2 }, combinator: 'and', conditions: [{ leftValue: expr("{{ $json.headers['x-leadgen-key'] }}"), operator: { type: 'string', operation: 'equals' }, rightValue: '<<INTAKE_API_KEY>>' }] } } } });

const OVERVIEW_SQL = "SELECT jsonb_build_object("
  + "'generated_at', now(),"
  + "'kpis', (SELECT jsonb_build_object('campaigns', count(*), 'active', count(*) FILTER (WHERE status IN ('created','discovering','analyzing','awaiting_approval','finalizing')), 'complete', count(*) FILTER (WHERE status='complete')) FROM leadgen.campaigns WHERE archived_at IS NULL),"
  + "'leads_kpis', (SELECT jsonb_build_object('total', count(*), 'hot', count(*) FILTER (WHERE classification='hot'), 'warm', count(*) FILTER (WHERE classification='warm'), 'cold', count(*) FILTER (WHERE classification='cold'), 'dq', count(*) FILTER (WHERE classification='disqualified')) FROM leadgen.campaign_leads WHERE archived_at IS NULL),"
  + "'campaigns', (SELECT coalesce(jsonb_agg(to_jsonb(c) ORDER BY c.created_at DESC), '[]'::jsonb) FROM ("
  + "  SELECT cam.id, cam.status, cam.quality_state, cam.budget_state, cam.business_type, cam.created_at, cam.geo_original, cam.geo_type, cam.depth, cam.volume_cap, cam.budget_cap_usd, cam.archived_at,"
  + "    (SELECT count(*) FROM leadgen.campaign_leads cl WHERE cl.campaign_id=cam.id AND cl.archived_at IS NULL) AS leads,"
  + "    (SELECT count(*) FROM leadgen.campaign_leads cl WHERE cl.campaign_id=cam.id AND cl.archived_at IS NULL AND cl.classification='hot') AS hot,"
  + "    (SELECT count(*) FROM leadgen.campaign_leads cl WHERE cl.campaign_id=cam.id AND cl.archived_at IS NULL AND cl.classification='warm') AS warm,"
  + "    (SELECT count(*) FROM leadgen.campaign_leads cl WHERE cl.campaign_id=cam.id AND cl.archived_at IS NULL AND cl.classification='cold') AS cold,"
  + "    (SELECT count(*) FROM leadgen.campaign_leads cl WHERE cl.campaign_id=cam.id AND cl.archived_at IS NULL AND cl.classification='disqualified') AS dq,"
  + "    (SELECT coalesce(sum(actual_usd),0) FROM leadgen.budget_transactions bt WHERE bt.campaign_id=cam.id AND bt.state='settled') AS spent_usd"
  + "  FROM leadgen.campaigns cam ORDER BY cam.created_at DESC LIMIT 60) c),"
  + "'fleet', (SELECT coalesce(jsonb_agg(to_jsonb(f) ORDER BY f.service, f.state), '[]'::jsonb) FROM (SELECT service, state, count(*) AS n FROM leadgen.work_items WHERE archived_at IS NULL GROUP BY service, state) f),"
  + "'stuck', (SELECT count(*) FROM leadgen.stuck_work_overview),"
  + "'notifications', (SELECT coalesce(jsonb_agg(to_jsonb(n) ORDER BY n.created_at DESC), '[]'::jsonb) FROM ("
  + "  SELECT sr.id AS id, sr.service AS service, sr.status AS type, sr.workflow_version AS version, wi.campaign_id AS campaign_id, c.business_type AS context, sr.started_at AS created_at,"
  + "    CASE WHEN sr.workflow_version LIKE '%degraded%' THEN 'Degraded mode / rate limit fallback active' WHEN sr.status = 'failed' THEN 'Worker failure - auto-retried' WHEN sr.work_attempt > 1 THEN 'Rate limit / retry attempt ' || sr.work_attempt || ' executed' ELSE 'System notice' END AS message"
  + "  FROM leadgen.service_runs sr JOIN leadgen.work_items wi ON wi.id = sr.work_item_id JOIN leadgen.campaigns c ON c.id = wi.campaign_id"
  + "  WHERE sr.status IN ('failed', 'retrying') OR sr.workflow_version LIKE '%degraded%' OR sr.work_attempt > 1 ORDER BY sr.started_at DESC LIMIT 30) n)"
  + ") AS payload";

const queryOverview = node({ type: 'n8n-nodes-base.postgres', version: 2.6, config: { name: 'Query Overview', position: [700, 260], onError: 'continueRegularOutput', parameters: { operation: 'executeQuery', query: OVERVIEW_SQL }, credentials: { postgres: newCredential('Postgres account') } }, output: [{ payload: {} }] });

const respondData = node({ type: 'n8n-nodes-base.respondToWebhook', version: 1.5, config: { name: 'Serve Data', position: [960, 260], parameters: { respondWith: 'json', responseBody: expr('={{ $json.payload || { "error": "no_data" } }}') } } });

const denyData = node({ type: 'n8n-nodes-base.respondToWebhook', version: 1.5, config: { name: 'Deny Data', position: [700, 440], parameters: { respondWith: 'json', responseBody: expr('={{ { "error": "unauthorized" } }}'), options: { responseCode: 401 } } } });

// ---------- 3) Leads data (JSON, ?campaign=<uuid>) ----------
const hookLeads = trigger({ type: 'n8n-nodes-base.webhook', version: 2.1, config: { name: 'Leads API', position: [200, 600], parameters: { httpMethod: 'GET', path: 'leadgen-console-leads', responseMode: 'responseNode' } }, output: [{ headers: {}, query: {} }] });

const authLeads = ifElse({ version: 2.2, config: { name: 'Leads Authorized?', position: [440, 600], parameters: { conditions: { options: { caseSensitive: true, leftValue: '', typeValidation: 'strict', version: 2 }, combinator: 'and', conditions: [{ leftValue: expr("{{ $json.headers['x-leadgen-key'] }}"), operator: { type: 'string', operation: 'equals' }, rightValue: '<<INTAKE_API_KEY>>' }] } } } });

// UUID-shape guard: a malformed ?campaign yields the nil uuid (empty result) rather than a cast error.
const cleanParams = node({ type: 'n8n-nodes-base.set', version: 3.4, config: { name: 'Clean Params', position: [700, 540], parameters: { mode: 'raw', includeOtherFields: false, jsonOutput: expr("={{ { campaign_id: /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/.test(($('Leads API').item.json.query && $('Leads API').item.json.query.campaign) || ($json.query && $json.query.campaign) || '') ? (($('Leads API').item.json.query && $('Leads API').item.json.query.campaign) || $json.query.campaign) : '00000000-0000-0000-0000-000000000000' } }}") } }, output: [{ campaign_id: '' }] });

const LEADS_SQL = "SELECT coalesce(jsonb_agg(to_jsonb(x) ORDER BY x.opportunity DESC NULLS LAST, x.name), '[]'::jsonb) AS payload FROM ("
  + " SELECT cl.id AS lead_id, b.business_name AS name, b.website_domain AS domain, b.phone_e164 AS phone, b.address, b.sales_status,"
  + " cl.classification, cl.classification_reason, cl.rediscovered, cl.hot_candidate, cl.critic_state, cl.archived_at,"
  + " (SELECT EXISTS (SELECT 1 FROM leadgen.service_runs sr JOIN leadgen.work_items wi ON wi.id=sr.work_item_id WHERE wi.campaign_lead_id=cl.id AND sr.workflow_version='cache-reuse-v1')) AS is_cached,"
  + " a.opportunity_score AS opportunity, a.contactability_score AS contactability, a.evidence_confidence AS confidence,"
  + " a.fit_web_seo AS web_seo, a.fit_voice_ai AS voice_ai, a.fit_ads_video AS ads_video, a.fit_consulting AS consulting, a.best_angle,"
  + " r.report_url, r.summary AS report_summary, r.prompt_version, r.model_version, r.validation AS report_validation,"
  + " (SELECT jsonb_object_agg(feature_key, val) FROM (SELECT DISTINCT ON (e.feature_key) e.feature_key, e.value_jsonb AS val FROM leadgen.evidence_items e WHERE e.business_id=b.id AND e.campaign_id=cl.campaign_id ORDER BY e.feature_key, e.observed_at DESC) ev) AS signals,"
  + " (SELECT coalesce(jsonb_agg(to_jsonb(ev_all) ORDER BY ev_all.observed_at DESC), '[]'::jsonb) FROM (SELECT e.feature_key, e.value_jsonb, e.value_type, e.product_tag, e.source_provider, e.observed_at, e.archived_at FROM leadgen.evidence_items e WHERE e.business_id=b.id AND e.campaign_id=cl.campaign_id ORDER BY e.observed_at DESC) ev_all) AS evidence_ledger,"
  + " (SELECT coalesce(jsonb_agg(to_jsonb(sr) ORDER BY sr.completed_at DESC NULLS LAST), '[]'::jsonb) FROM (SELECT sr.service, sr.started_at, sr.completed_at, sr.status FROM leadgen.service_runs sr JOIN leadgen.work_items wi ON wi.id=sr.work_item_id WHERE wi.campaign_lead_id=cl.id ORDER BY sr.completed_at DESC) sr) AS service_runs"
  + " FROM leadgen.campaign_leads cl JOIN leadgen.businesses b ON b.id=cl.business_id"
  + " LEFT JOIN leadgen.lead_assessments a ON a.id=cl.latest_assessment_id"
  + " LEFT JOIN leadgen.lead_reports r ON r.campaign_lead_id=cl.id"
  + " WHERE cl.campaign_id = $1::uuid) x";

const queryLeads = node({ type: 'n8n-nodes-base.postgres', version: 2.6, config: { name: 'Query Leads', position: [960, 540], onError: 'continueRegularOutput', parameters: { operation: 'executeQuery', query: LEADS_SQL, options: { queryReplacement: expr('={{ $json.campaign_id }}') } }, credentials: { postgres: newCredential('Postgres account') } }, output: [{ payload: [] }] });

const respondLeads = node({ type: 'n8n-nodes-base.respondToWebhook', version: 1.5, config: { name: 'Serve Leads', position: [1200, 540], parameters: { respondWith: 'json', responseBody: expr('={{ $json.payload || [] }}') } } });

const denyLeads = node({ type: 'n8n-nodes-base.respondToWebhook', version: 1.5, config: { name: 'Deny Leads', position: [700, 700], parameters: { respondWith: 'json', responseBody: expr('={{ { "error": "unauthorized" } }}'), options: { responseCode: 401 } } } });

// ---------- 4) Action API (POST /leadgen-console-action) ----------
const hookAction = trigger({ type: 'n8n-nodes-base.webhook', version: 2.1, config: { name: 'Action API', position: [200, 800], parameters: { httpMethod: 'POST', path: 'leadgen-console-action', responseMode: 'responseNode' } }, output: [{ body: {}, headers: {} }] });

const authAction = ifElse({ version: 2.2, config: { name: 'Action Authorized?', position: [440, 800], parameters: { conditions: { options: { caseSensitive: true, leftValue: '', typeValidation: 'strict', version: 2 }, combinator: 'and', conditions: [{ leftValue: expr("{{ $json.headers['x-leadgen-key'] }}"), operator: { type: 'string', operation: 'equals' }, rightValue: '<<INTAKE_API_KEY>>' }] } } } });

const execAction = node({ type: 'n8n-nodes-base.postgres', version: 2.6, config: { name: 'Execute Action', position: [700, 800], onError: 'continueRegularOutput', parameters: { operation: 'executeQuery', query: "SELECT CASE WHEN ($1->>'action') = 'archive_campaign' THEN leadgen.archive_campaign(($1->>'campaign_id')::uuid) WHEN ($1->>'action') = 'reanalyze' THEN leadgen.requeue_lead_analysis(($1->>'lead_id')::uuid) ELSE leadgen.archive_lead(($1->>'lead_id')::uuid) END AS payload", options: { queryReplacement: expr('={{ $json.body }}') } }, credentials: { postgres: newCredential('Postgres account') } }, output: [{ payload: {} }] });

const respondAction = node({ type: 'n8n-nodes-base.respondToWebhook', version: 1.5, config: { name: 'Serve Action', position: [960, 800], parameters: { respondWith: 'json', responseBody: expr('={{ $json.payload || { "ok": true } }}'), options: { responseHeaders: { entries: [{ name: 'Access-Control-Allow-Origin', value: '*' }, { name: 'Access-Control-Allow-Headers', value: '*' }, { name: 'Access-Control-Allow-Methods', value: 'GET, POST, OPTIONS' }] } } } } });

const denyAction = node({ type: 'n8n-nodes-base.respondToWebhook', version: 1.5, config: { name: 'Deny Action', position: [700, 940], parameters: { respondWith: 'json', responseBody: expr('={{ { "error": "unauthorized" } }}'), options: { responseCode: 401 } } } });

const note = sticky('## Ops Console (internal, read-only + launch)\n\nSelf-contained SPA served by n8n over the prod ledger (SELECT only, no DML). Three GET webhooks: /leadgen-console (HTML), /leadgen-console-data (KPIs + campaigns + fleet health), /leadgen-console-leads?campaign= (leads + signals + report links). Data/leads endpoints gated by x-leadgen-key (redacted; set on deployed instance). New-campaign form reuses the intake API.', [renderPage, queryOverview, queryLeads], { color: 5 });

export default workflow('leadgen-ops-console', 'Leadgen — Ops Console')
  .add(hookPage).to(renderPage).to(respondPage)
  .add(hookData).to(authData.onTrue(queryOverview.to(respondData)).onFalse(denyData))
  .add(hookLeads).to(authLeads.onTrue(cleanParams.to(queryLeads).to(respondLeads)).onFalse(denyLeads))
  .add(hookAction).to(authAction.onTrue(execAction.to(respondAction)).onFalse(denyAction))
  .add(note);
