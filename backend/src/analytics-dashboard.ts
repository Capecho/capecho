// Self-contained admin dashboard for the analytics readout, served by the Worker at
// GET /analytics/dashboard. The HTML shell carries NO data: it prompts for METRICS_ADMIN_TOKEN and
// fetches /analytics/summary (same origin) with a Bearer header, so the data stays token-gated while
// the shell can be served openly. No external scripts/styles (CSP-friendly, works offline). noindex.
//
// NOTE: the embedded <script> deliberately uses string concatenation (no template literals / no `${`)
// so the whole document can live inside this TS template literal without interpolation collisions.
export const ANALYTICS_DASHBOARD_HTML = `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8"/>
<meta name="viewport" content="width=device-width, initial-scale=1"/>
<meta name="robots" content="noindex"/>
<title>Capecho · Analytics</title>
<style>
  :root { --bg:#faf8f4; --panel:#fff; --ink:#1f1c19; --ink2:#6b6358; --line:#e7e1d8; --accent:#b25d3b; }
  * { box-sizing:border-box; }
  body { margin:0; background:var(--bg); color:var(--ink); font:15px/1.5 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,Helvetica,Arial,sans-serif; }
  .wrap { max-width:1000px; margin:0 auto; padding:28px 20px 80px; }
  h1 { font-size:22px; margin:0 0 2px; }
  .sub { color:var(--ink2); font-size:13px; margin:0 0 18px; }
  .bar { display:flex; gap:8px; flex-wrap:wrap; align-items:center; }
  input { font:inherit; padding:8px 10px; border:1px solid var(--line); border-radius:8px; background:var(--panel); color:var(--ink); }
  input#token { width:280px; }
  input#cap { width:110px; }
  button { font:inherit; padding:8px 14px; border:1px solid var(--accent); background:var(--accent); color:#fff; border-radius:8px; cursor:pointer; }
  button.ghost { background:#fff; color:var(--ink2); border-color:var(--line); }
  button:hover { filter:brightness(1.04); }
  .status { color:var(--ink2); font-size:13px; min-height:18px; margin:10px 0 4px; }
  .meta { color:var(--ink2); font-size:12px; margin:4px 0 6px; }
  .grid { display:grid; gap:12px; grid-template-columns:repeat(auto-fill,minmax(160px,1fr)); margin:8px 0 6px; }
  .card { background:var(--panel); border:1px solid var(--line); border-radius:12px; padding:14px; }
  .card .k { font-size:11px; text-transform:uppercase; letter-spacing:.06em; color:var(--ink2); }
  .card .v { font-size:26px; font-weight:600; margin-top:4px; }
  .card .s { font-size:12px; color:var(--ink2); margin-top:2px; }
  h2 { font-size:13px; text-transform:uppercase; letter-spacing:.06em; color:var(--ink2); margin:26px 0 6px; border-top:1px solid var(--line); padding-top:16px; }
  table { width:100%; border-collapse:collapse; font-size:13px; background:var(--panel); border:1px solid var(--line); border-radius:12px; overflow:hidden; }
  th,td { text-align:right; padding:7px 10px; border-bottom:1px solid var(--line); }
  th:first-child, td:first-child { text-align:left; }
  th { font-size:11px; text-transform:uppercase; letter-spacing:.05em; color:var(--ink2); }
  tr:last-child td { border-bottom:none; }
  .hide { display:none; }
</style>
</head>
<body>
<div class="wrap">
  <h1>Capecho · Analytics</h1>
  <p class="sub">First-party retention &amp; willingness-to-pay readout. Enter the admin token to load.</p>
  <div class="bar">
    <input id="token" type="password" placeholder="METRICS_ADMIN_TOKEN" autocomplete="off" spellcheck="false"/>
    <input id="cap" type="number" min="1" placeholder="quota cap (10)"/>
    <button id="load">Load</button>
    <button id="forget" class="ghost">Forget token</button>
  </div>
  <div class="status" id="status"></div>
  <div id="results" class="hide">
    <div class="meta" id="meta"></div>
    <h2>Retention (returned within N days)</h2>
    <div class="grid" id="retention"></div>
    <h2>Active users</h2>
    <div class="grid" id="active"></div>
    <h2>Capture</h2>
    <div class="grid" id="capture"></div>
    <h2>Review</h2>
    <div class="grid" id="review"></div>
    <h2>Willingness to pay (context layer)</h2>
    <div class="grid" id="wtp"></div>
    <h2>Accounts</h2>
    <div class="grid" id="accounts"></div>
    <h2>Cohorts (by sign-up day)</h2>
    <table id="cohorts"><thead><tr><th>Sign-up day</th><th>Size</th><th>D1</th><th>D7</th><th>D30</th></tr></thead><tbody></tbody></table>
  </div>
</div>
<script>
(function(){
  var TOKEN_KEY='capecho-analytics-token';
  function $(s){ return document.querySelector(s); }
  function pct(r){ return (r==null) ? '—' : (r*100).toFixed(1)+'%'; }
  function num(n){ return (n==null) ? '—' : String(n); }
  function esc(x){ return String(x).replace(/[&<>]/g, function(c){ return c==='&'?'&amp;':(c==='<'?'&lt;':'&gt;'); }); }
  function card(k,v,s){ return '<div class="card"><div class="k">'+esc(k)+'</div><div class="v">'+v+'</div>'+(s?('<div class="s">'+esc(s)+'</div>'):'')+'</div>'; }

  function render(d){
    $('#results').classList.remove('hide');
    var gen = new Date(d.generatedAtMs).toISOString().replace('T',' ').slice(0,16)+' UTC';
    $('#meta').textContent = 'Generated '+gen+' · quota cap '+d.quotaCap+' · '+d.notes;

    $('#retention').innerHTML = (d.retention||[]).map(function(b){
      return card('D'+b.days, pct(b.rate), b.returned+' / '+b.eligible+' eligible');
    }).join('') || card('—','—');

    var ac=d.active||{};
    $('#active').innerHTML = card('DAU',num(ac.dauUtc),'last 1 UTC day')
      + card('WAU',num(ac.wauUtc),'last 7 UTC days')
      + card('MAU',num(ac.mauUtc),'last 30 UTC days');

    var c=d.capture||{};
    $('#capture').innerHTML = card('Total saves',num(c.totalSaves))
      + card('Live words',num(c.liveWords))
      + card('Capturing users',num(c.capturingUsers))
      + card('Avg saves / user', c.avgSavesPerCapturingUser==null?'—':String(c.avgSavesPerCapturingUser))
      + card('Median saves / user', c.medianSavesPerCapturingUser==null?'—':String(c.medianSavesPerCapturingUser));

    var rv=d.review||{};
    $('#review').innerHTML = card('Total reviews',num(rv.totalReviews))
      + card('Reviewing users',num(rv.reviewingUsers))
      + card('Reviews / save', pct(rv.reviewsPerSave))
      + card('% who review', pct(rv.pctCapturingUsersWhoReview),'of capturing users');

    var w=d.willingnessToPay||{};
    $('#wtp').innerHTML = card('Context users',num(w.contextUsers))
      + card('In-context total', num(w.totalContextExplanations))
      + card('Adoption', pct(w.adoptionRate),'of active accounts')
      + card('Cap hits', num(w.userDayCapHits),'user·days at the free cap')
      + card('Users who hit cap', num(w.usersWhoHitCap))
      + card('Max / user·day', num(w.maxPerUserDay));

    var a=d.accounts||{};
    var bp=a.byProvider||{};
    var prov = Object.keys(bp).map(function(k){ return k+': '+bp[k]; }).join(' · ') || '—';
    $('#accounts').innerHTML = card('Total',num(a.total))
      + card('Active',num(a.active))
      + card('Deleted',num(a.deleted))
      + '<div class="card"><div class="k">By provider</div><div class="v" style="font-size:15px;font-weight:500;margin-top:8px">'+esc(prov)+'</div></div>';

    $('#cohorts tbody').innerHTML = (d.cohorts||[]).map(function(co){
      function cell(r){ return r + (co.size>0 ? (' <span style="color:var(--ink2)">('+Math.round(r/co.size*100)+'%)</span>') : ''); }
      return '<tr><td>'+esc(co.day)+'</td><td>'+co.size+'</td><td>'+cell(co.returnedWithin1)+'</td><td>'+cell(co.returnedWithin7)+'</td><td>'+cell(co.returnedWithin30)+'</td></tr>';
    }).join('') || '<tr><td colspan="5" style="text-align:center;color:var(--ink2)">No cohorts yet</td></tr>';
  }
  window.render = render;

  function load(){
    var token=$('#token').value.trim();
    var cap=$('#cap').value.trim();
    if(!token){ $('#status').textContent='Enter the admin token (METRICS_ADMIN_TOKEN).'; return; }
    localStorage.setItem(TOKEN_KEY, token);
    $('#status').textContent='Loading…';
    var qs = cap ? ('?quotaCap='+encodeURIComponent(cap)) : '';
    fetch('/analytics/summary'+qs, { headers: { authorization: 'Bearer '+token } })
      .then(function(res){
        if(res.status===401){ throw new Error('Unauthorized — check the admin token.'); }
        if(!res.ok){ throw new Error('Request failed: '+res.status); }
        return res.json();
      })
      .then(function(d){ render(d); $('#status').textContent=''; })
      .catch(function(e){ $('#status').textContent=e.message; });
  }

  $('#load').addEventListener('click', load);
  $('#forget').addEventListener('click', function(){ localStorage.removeItem(TOKEN_KEY); $('#token').value=''; $('#results').classList.add('hide'); $('#status').textContent='Token forgotten.'; });

  var saved=localStorage.getItem(TOKEN_KEY);
  if(saved){ $('#token').value=saved; load(); }
})();
</script>
</body>
</html>
`;
