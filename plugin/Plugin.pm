package Plugins::AuraSpotifyStatus::Plugin;

# Aura Spotify-in-LMS — Status plugin (THIN, self-contained on LMS's own port).
#
# Adds a click-to-open "Aura Spotify Status" page to the LMS UI. It is THIN: it does
# NOT reimplement the health collector — the real collection lives in our standalone
# helper spotify-status.py (127.0.0.1:8795). This plugin only:
#   1) serves the dashboard HTML at /plugins/AuraSpotifyStatus/status.html, and
#   2) PROXIES the JSON at /plugins/AuraSpotifyStatus/data -> the helper's :8795/data.
# Serving BOTH from LMS's own port (:9000) keeps everything same-origin, so it works
# no matter how the LMS UI is reached (LAN :9000 or the MeshCentral tunnel) — no
# dependency on nginx / :80 / cross-origin iframes.
#
# SURVIVES SPOTTY UPGRADES: this is its OWN plugin dir
# (InstalledPlugins/Plugins/AuraSpotifyStatus/). A Spotty update only rewrites
# Plugins/Spotty/ — never this. Zero Spotty files touched.

use strict;
use base qw(Slim::Plugin::Base);

use Slim::Utils::Log;
use Slim::Networking::SimpleAsyncHTTP;

my $log = Slim::Utils::Log->addLogCategory({
    category     => 'plugin.auraspotifystatus',
    defaultLevel => 'INFO',
    description  => 'PLUGIN_AURASPOTIFYSTATUS_NAME',
});

# The standalone Python helper (spotify-status.py) that actually collects health.
my $HELPER_DATA = 'http://127.0.0.1:8795/data';

sub getDisplayName { 'PLUGIN_AURASPOTIFYSTATUS_NAME' }

sub initPlugin {
    my $class = shift;
    $class->SUPER::initPlugin(@_);

    require Slim::Web::Pages;
    # HTML dashboard (also the plugin's optionsURL -> appears under LMS Settings).
    Slim::Web::Pages->addPageFunction('plugins/AuraSpotifyStatus/status.html', \&_pageHandler);
    # JSON proxy -> the Python helper. addRawFunction lets us stream a raw body + async.
    Slim::Web::Pages->addRawFunction('plugins/AuraSpotifyStatus/data', \&_dataHandler);

    # Add a clickable entry to the LMS web UI's plugins menu.
    if (Slim::Web::Pages->can('addPageLinks')) {
        Slim::Web::Pages->addPageLinks('plugins',
            { 'PLUGIN_AURASPOTIFYSTATUS_NAME' => 'plugins/AuraSpotifyStatus/status.html' });
    }

    $log->info('Aura Spotify Status plugin initialised (same-origin dashboard + :8795 data proxy)');
    return 1;
}

# ---- JSON proxy: fetch the helper's /data and return it verbatim (async) ----
sub _dataHandler {
    my ($httpClient, $response, $func, $callback, @args) = @_;

    my $ok = sub {
        my $http = shift;
        _reply($httpClient, $response, 200, 'application/json', $http->content);
    };
    my $err = sub {
        # helper down -> report it as JSON so the page shows a clean banner instead of hanging
        _reply($httpClient, $response, 200, 'application/json',
            '{"error":"status helper (spotify-status.py :8795) not responding"}');
    };

    Slim::Networking::SimpleAsyncHTTP->new($ok, $err, { timeout => 4 })->get($HELPER_DATA);
    return; # async — reply is sent from the callbacks
}

sub _reply {
    my ($httpClient, $response, $code, $ctype, $body) = @_;
    $body = '' unless defined $body;
    $response->code($code);
    $response->header('Content-Type'  => $ctype);
    $response->header('Cache-Control' => 'no-store');
    Slim::Web::HTTP::addHTTPResponse($httpClient, $response, \$body);
}

# ---- The dashboard HTML (fetches SAME-ORIGIN /plugins/AuraSpotifyStatus/data) ----
sub _pageHandler {
    my ($client, $params) = @_;
    my $html = _dashboard_html();
    return \$html;
}

sub _dashboard_html {
    return <<'HTML';
<!DOCTYPE html><html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Aura Spotify Status</title><style>
body{background:#1a1a1a;color:#e0e0e0;font-family:sans-serif;margin:0;padding:24px 16px}
header{max-width:900px;margin:0 auto 16px}
header h1{font-size:20px;font-weight:600;margin:0 0 4px}
header p{font-size:13px;opacity:.5;margin:0 0 8px}
#pi{color:#1db954;font-size:13px;opacity:.7;transition:opacity .2s}
#lu{font-size:13px;opacity:.5;margin-left:16px}
#eb{display:none;background:rgba(229,57,53,.15);color:#e53935;padding:8px 16px;border-radius:4px;margin:0 auto 16px;text-align:center;max-width:900px}
.grid{display:grid;grid-template-columns:repeat(2,1fr);gap:16px;max-width:900px;margin:0 auto}
@media(max-width:600px){.grid{grid-template-columns:1fr}}
.card{background:#242424;border-radius:8px;padding:16px;border:1px solid rgba(255,255,255,.08)}
.card h2{margin:0 0 12px;font-size:16px;font-weight:600;opacity:.7;text-transform:uppercase;letter-spacing:.05em}
.r{display:flex;justify-content:space-between;padding:4px 0;font-size:14px}
.l{opacity:.6;font-size:13px}.v{font-weight:400}
.a{color:#1db954}.d{color:#e53935}.u{color:rgba(224,224,224,.3)}.w{color:#f5a623}
.er{padding:4px 0;font-size:13px;border-left:3px solid transparent;padding-left:8px}
.er.e{border-left-color:#e53935}.er.wn{border-left-color:#f5a623}
.em{font-family:monospace;font-size:13px}.emsg{margin-left:8px}
.mono{font-family:monospace;font-size:13px}.muted{opacity:.5}
hr{border:0;border-top:1px solid rgba(255,255,255,.1);margin:8px 0}
footer{text-align:center;opacity:.4;font-size:13px;margin:24px auto 0;max-width:900px}
</style></head><body>
<header><h1>Aura Spotify-in-LMS &mdash; Status</h1>
<p>Widevine/Electron decoder health &mdash; auto-updating every 5 seconds</p>
<span id="pi">&#9679; Live</span><span id="lu" class="muted"></span></header>
<div id="eb">Status unavailable &mdash; retrying.</div>
<div class="grid">
<div class="card"><h2>Decoder (Widevine)</h2><div id="c-dec"></div></div>
<div class="card"><h2>Auth</h2><div id="c-auth"></div></div>
<div class="card"><h2>Services</h2><div id="c-svc"></div></div>
<div class="card"><h2>System</h2><div id="c-sys"></div></div>
<div class="card" style="grid-column:1/-1"><h2>Recent Errors</h2><div id="c-err"></div></div>
</div>
<footer>Aura Spotify-in-LMS &mdash; status plugin (survives Spotty updates)</footer>
<script>
function fUp(s){if(!s&&s!==0)return '—';var d=Math.floor(s/86400),h=Math.floor((s%86400)/3600),m=Math.floor((s%3600)/60);return d>0?d+'d '+h+'h '+m+'m':h+'h '+m+'m';}
function row(l,v,c){var r=document.createElement('div');r.className='r';var a=document.createElement('span');a.className='l';a.textContent=l;var b=document.createElement('span');b.className='v'+(c?' '+c:'');b.textContent=(v===null||v===undefined)?'—':String(v);r.appendChild(a);r.appendChild(b);return r;}
function clr(id){var e=document.getElementById(id);e.textContent='';return e;}
function rDec(d){var b=clr('c-dec');var e=d.decoder||{};b.appendChild(row('SDK Ready',e.ready?'Yes':'No',e.ready?'a':'d'));b.appendChild(row('Device (Aura-M)',e.deviceId||'—','mono'));if(e.track){var p=row('Now Playing','▶ '+e.track);p.querySelector('.v').style.color='#1db954';b.appendChild(p);b.appendChild(row('Artist',e.artist));b.appendChild(row('Position',Math.floor(e.position)+'s / '+Math.floor(e.duration)+'s'));}else b.appendChild(row('Playback',e.paused===false?'playing':'idle'));}
function rAuth(d){var b=clr('c-auth');var a=d.auth||{};b.appendChild(row('Harness Token',a.tokenPresent?'Present':'Missing',a.tokenPresent?'a':'d'));b.appendChild(row('Account',a.account||'—','mono'));b.appendChild(row('Product',a.product||'—',a.product==='premium'?'a':'w'));b.appendChild(row('Country',a.country));if('auraM' in a)b.appendChild(row('Aura-M Registered',a.auraM?'Yes':'No',a.auraM?'a':'w'));b.appendChild(row('Rides Spotty acct',a.spottyAccount||'—','mono'));}
function rSvc(d){var b=clr('c-svc');var s=d.services||[];var up=0;s.forEach(function(x){if(x.alive)up++;});b.appendChild(row('Active',up+' / '+s.length,up===s.length?'a':'w'));b.appendChild(document.createElement('hr'));s.forEach(function(x){var r=document.createElement('div');r.className='r';var l=document.createElement('span');l.className='l';var dot=document.createElement('span');dot.className=x.alive?'a':'d';dot.textContent='● ';l.appendChild(dot);l.appendChild(document.createTextNode(x.name.replace('spotify-','')));var v=document.createElement('span');v.className='v muted';v.textContent=x.alive?fUp(x.uptime):x.active;r.appendChild(l);r.appendChild(v);b.appendChild(r);});}
function rSys(d){var b=clr('c-sys');var s=d.system||{};b.appendChild(row('Version',s.version?'v'+s.version:'—'));b.appendChild(row('LMS',s.lms?'reachable':'down',s.lms?'a':'d'));b.appendChild(row('Loopback (snd-aloop)',s.loopback?'present':'MISSING',s.loopback?'a':'d'));b.appendChild(row('Hub :8790',s.hub?'serving':'down',s.hub?'a':'d'));b.appendChild(row('Spotty wiring',s.spottyWired?'installed':'NOT wired',s.spottyWired?'a':'w'));b.appendChild(document.createElement('hr'));b.appendChild(row('Decode engine',s.decodeEngine||'—'));b.appendChild(row('librespot outage','immune','a'));}
function rErr(d){var b=clr('c-err');var es=d.errors||[];if(!es.length){var m=document.createElement('div');m.className='muted';m.textContent='No errors recorded.';b.appendChild(m);return;}es.forEach(function(e){var r=document.createElement('div');r.className='er';var lo=(e.message||'').toLowerCase();if(/error|fail|denied|invalid/.test(lo))r.className+=' e';else r.className+=' wn';var mod=document.createElement('span');mod.className='em';mod.textContent='['+(e.module||'')+']';r.appendChild(mod);var msg=document.createElement('span');msg.className='emsg';msg.textContent=e.message||'';r.appendChild(msg);b.appendChild(r);});}
function render(d){if(d.error){document.getElementById('eb').style.display='block';document.getElementById('eb').textContent=d.error;return;}rDec(d);rAuth(d);rSvc(d);rSys(d);rErr(d);}
var t;function poll(){var x=new XMLHttpRequest();x.timeout=5000;x.open('GET','data',true);x.onload=function(){if(x.status===200){try{render(JSON.parse(x.responseText));document.getElementById('eb').style.display='none';var i=document.getElementById('pi');i.style.opacity='1';setTimeout(function(){i.style.opacity='0.7';},200);document.getElementById('lu').textContent='Updated: '+new Date().toLocaleTimeString();}catch(e){document.getElementById('eb').style.display='block';}}else document.getElementById('eb').style.display='block';t=setTimeout(poll,5000);};x.ontimeout=x.onerror=function(){document.getElementById('eb').style.display='block';t=setTimeout(poll,5000);};x.send();}
document.addEventListener('visibilitychange',function(){if(document.hidden)clearTimeout(t);else{clearTimeout(t);poll();}});poll();
</script></body></html>
HTML
}

1;
