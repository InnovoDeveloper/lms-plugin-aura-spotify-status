package Plugins::AuraSpotifyStatus::Plugin;

# Aura Spotify-in-LMS — Status plugin (NATIVE, self-contained).
#
# Adds a click-to-open "Aura Spotify Status" health dashboard to the LMS UI.
# TRUE NATIVE PLUGIN: the Perl collects ALL health data ITSELF, synchronously,
# in-process (like SpotOn's Status.pm) and serves it at
# /plugins/AuraSpotifyStatus/data. There is NO proxy to the Python helper and NO
# nginx dependency — so it works same-origin on LMS's own port (:9000) over LAN and
# the MeshCentral tunnel, with none of the SimpleAsyncHTTP-to-localhost hang the old
# proxy version had.
#
# (The standalone Python dashboard at /spotify-status/ :8795 is unrelated and stays
# as an independent page.)
#
# SURVIVES SPOTTY UPGRADES: its own plugin dir (Plugins/AuraSpotifyStatus/). A Spotty
# update only rewrites Plugins/Spotty/ — never this. Zero Spotty files touched.

use strict;
use base qw(Slim::Plugin::Base);

use JSON::XS::VersionOneAndTwo;
use Slim::Utils::Log;
use Slim::Utils::Network;

my $log = Slim::Utils::Log->addLogCategory({
    category     => 'plugin.auraspotifystatus',
    defaultLevel => 'INFO',
    description  => 'PLUGIN_AURASPOTIFYSTATUS_NAME',
});

my $ROUTE1  = '/opt/route1';
my $MARKER  = '/mnt/dietpi_userdata/innovo/config/versions/aura-spotify.json';
my $SPOTTY_BIN = '/var/lib/squeezeboxserver/cache/InstalledPlugins/Plugins/Spotty/Bin/aarch64-linux';

my @SERVICES = qw(
    spotify-xvfb spotify-harness spotify-electron spotify-loopback-capture
    spotify-nowplaying spotify-advancer spotify-account-follow spotify-exclusive
    spotify-sdk-watchdog
);

my @ERROR_LOGS = (
    '/var/log/route2-helper.log', '/var/log/spotify-advancer.log',
    '/var/log/spotify-sdk-watchdog.log', '/var/log/spotify-account-follow.log',
    '/var/log/loopback-capture.err',
);

sub getDisplayName { 'PLUGIN_AURASPOTIFYSTATUS_NAME' }

sub initPlugin {
    my $class = shift;
    $class->SUPER::initPlugin(@_);

    require Slim::Web::Pages;
    Slim::Web::Pages->addPageFunction('plugins/AuraSpotifyStatus/status.html', \&_pageHandler);
    Slim::Web::Pages->addRawFunction('plugins/AuraSpotifyStatus/data', \&_dataHandler);

    if (Slim::Web::Pages->can('addPageLinks')) {
        Slim::Web::Pages->addPageLinks('plugins',
            { 'PLUGIN_AURASPOTIFYSTATUS_NAME' => 'plugins/AuraSpotifyStatus/status.html' });
    }

    $log->info('Aura Spotify Status plugin initialised (native in-process collector)');
    return 1;
}

# ==================== data collection (all synchronous, eval-guarded) ====================

# quick TCP connect check to a localhost port (ready-ish signal without a slow HTTP round-trip)
sub _port_open {
    my ($port) = @_;
    require IO::Socket::INET;
    my $s = IO::Socket::INET->new(PeerAddr => '127.0.0.1', PeerPort => $port, Proto => 'tcp', Timeout => 1);
    if ($s) { close $s; return 1; }
    return 0;
}

# GET a small JSON body from a localhost port. Uses a select-based read with a HARD
# wall-clock deadline and a byte cap — never blocks on EOF/keep-alive (which is what
# hung the LMS event loop: a slurp <$s> waits for the peer to CLOSE, and alarm() is
# swallowed by LMS's async signal handling so it never fires). This is bounded + safe.
sub _get_json {
    my ($port, $path) = @_;
    require IO::Socket::INET;
    require IO::Select;
    my $s = IO::Socket::INET->new(PeerAddr => '127.0.0.1', PeerPort => $port,
                                  Proto => 'tcp', Timeout => 1) or return undef;
    $s->blocking(0);
    my $sel = IO::Select->new($s);
    # send request (small; a single non-blocking write is fine for a short GET line)
    syswrite($s, "GET $path HTTP/1.0\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n");
    my $resp = '';
    my $deadline = time() + 2;                      # hard 2s wall-clock cap
    while (time() < $deadline && length($resp) < 65536) {
        my @ready = $sel->can_read(0.3) or next;    # wait up to 300ms for data
        my $chunk = '';
        my $n = sysread($s, $chunk, 8192);
        last if !defined $n;                        # error
        last if $n == 0;                            # peer closed — done
        $resp .= $chunk;
        last if $resp =~ /\r\n\r\n.*\}\s*\z/s;       # got headers + a complete-looking JSON body
    }
    close $s;
    my ($body) = $resp =~ /\r\n\r\n(.*)\z/s;
    return undef unless defined $body && length $body;
    my $j = eval { from_json($body) };
    return $j;
}

sub _services {
    # ONE batched systemctl call for all units (not 18 forks) — keeps the LMS event
    # loop unblocked and the whole handler ~sub-second. `show` prints an Id= line per
    # unit in request order, so we can pair each block back to its service name.
    my $list = join(' ', @SERVICES);
    my $out = `systemctl show -p Id -p ActiveState -p ActiveEnterTimestampMonotonic $list 2>/dev/null` // '';
    my $up  = (split /\s+/, do { local (@ARGV,$/) = '/proc/uptime'; my $x = <>; $x // '' })[0];

    my %info;
    my $cur;
    for my $line (split /\n/, $out) {
        if ($line =~ /^Id=(.+)$/) { $cur = $1; $cur =~ s/\.service$//; $info{$cur} = {}; }
        elsif ($cur && $line =~ /^ActiveState=(.+)$/) { $info{$cur}{active} = $1; }
        elsif ($cur && $line =~ /^ActiveEnterTimestampMonotonic=(\d+)$/) { $info{$cur}{mono} = $1; }
    }

    my @rows;
    for my $s (@SERVICES) {
        my $active = $info{$s}{active} // 'unknown';
        my $mono   = $info{$s}{mono};
        my $uptime;
        if (defined $up && $mono && $mono ne '0') {
            $uptime = int($up - ($mono / 1_000_000));
            $uptime = 0 if $uptime < 0;
        }
        push @rows, { name => $s, active => $active, alive => ($active eq 'active' ? \1 : \0), uptime => $uptime };
    }
    return \@rows;
}

sub _decoder {
    my $d = _get_json(5590, '/state') || {};
    return {
        ready    => ($d->{ready} ? \1 : \0),
        deviceId => substr($d->{deviceId} // '', 0, 16),
        paused   => (defined $d->{paused} ? ($d->{paused} ? \1 : \0) : undef),
        track    => $d->{name},
        artist   => $d->{artist},
        position => ($d->{position} // 0) / 1000.0,
        duration => ($d->{duration} // 0) / 1000.0,
        uri      => $d->{uri},
    };
}

sub _auth {
    my %a;
    my $t = _get_json(5588, '/token') || {};
    $a{tokenPresent} = ($t->{token} ? \1 : \0);
    # ride-on Spotty account (passive read of spotty.prefs)
    if (open my $fh, '<', '/var/lib/squeezeboxserver/prefs/plugin/spotty.prefs') {
        while (my $l = <$fh>) { if ($l =~ /^\s*account:\s*([a-f0-9]+)\s*$/) { $a{spottyAccount} = $1; last; } }
        close $fh;
    }
    return \%a;
}

sub _system {
    my %s;
    if (open my $fh, '<', $MARKER) { local $/; my $j = eval { from_json(<$fh>) }; close $fh; $s{version} = $j->{version} if $j; }
    $s{lms}      = \1;                          # if this handler runs, LMS is up
    $s{loopback} = (do { local (@ARGV,$/)='/proc/asound/cards'; (my $x=<>) =~ /loopback/i ? 1 : 0 }) ? \1 : \0;
    $s{hub}      = _port_open(8790) ? \1 : \0;
    $s{spottyWired} = (-f "$SPOTTY_BIN/spotty" && -f "$SPOTTY_BIN/spotty.real") ? \1 : \0;
    $s{decodeEngine}    = 'CastLabs Electron + Widevine (Web Playback SDK)';
    $s{librespotImmune} = \1;
    return \%s;
}

sub _errors {
    my @rows;
    for my $lg (@ERROR_LOGS) {
        open my $fh, '<', $lg or next;
        my @lines = <$fh>; close $fh;
        @lines = @lines[-40 .. -1] if @lines > 40;
        (my $mod = $lg) =~ s{.*/}{}; $mod =~ s/\.(log|err)$//;
        for my $ln (@lines) {
            next unless $ln =~ /\b(err|error|warn|fail|429|missing|denied|invalid)\b/i;
            # Suppress benign, self-resolved watchdog chatter — these match "missing"
            # but are informational, not faults:
            #   "Aura-M MISSING (1/3)" / "(2/3)" — a transient blip that hadn't yet hit
            #     the heal threshold (only "(3/3)" means it actually acted → keep that).
            #   "back (was missing ...)" — a recovery notice.
            #   "watchdog start ..." — a startup banner.
            next if $ln =~ /MISSING \([0-2]\/\d+\)/;   # under-threshold blip (3/3+ kept)
            next if $ln =~ /back \(was missing/i;       # recovered
            next if $ln =~ /watchdog start/i;           # startup banner
            chomp $ln; push @rows, { module => $mod, message => substr($ln, 0, 120) };
        }
    }
    @rows = @rows[-15 .. -1] if @rows > 15;
    return \@rows;
}

sub _dataHandler {
    my ($httpClient, $response) = @_;
    my %data;
    $data{decoder}  = eval { _decoder() }  // {};
    $data{auth}     = eval { _auth() }     // {};
    $data{services} = eval { _services() } // [];
    $data{system}   = eval { _system() }   // {};
    $data{errors}   = eval { _errors() }   // [];
    $data{ts}       = time();

    my $bytes = to_json(\%data);
    # NOTE: a raw (addRawFunction) handler owns the whole HTTP response. LMS will HANG
    # the connection unless Content-Length is set explicitly — without it the client
    # keeps the socket open waiting for more. (This mirrors SpotOn's _jsonResponse; the
    # earlier "hang" was a MISSING Content-Length, not slow collection.)
    $response->header('Content-Length' => length($bytes));
    $response->code(200);
    $response->header('Connection'    => 'close');
    $response->header('Cache-Control' => 'no-store');
    $response->content_type('application/json');
    Slim::Web::HTTP::addHTTPResponse($httpClient, $response, \$bytes);
}

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
<footer>Aura Spotify-in-LMS &mdash; native LMS status plugin (survives Spotty updates)</footer>
<script>
function fUp(s){if(!s&&s!==0)return '—';var d=Math.floor(s/86400),h=Math.floor((s%86400)/3600),m=Math.floor((s%3600)/60);return d>0?d+'d '+h+'h '+m+'m':h+'h '+m+'m';}
function row(l,v,c){var r=document.createElement('div');r.className='r';var a=document.createElement('span');a.className='l';a.textContent=l;var b=document.createElement('span');b.className='v'+(c?' '+c:'');b.textContent=(v===null||v===undefined)?'—':String(v);r.appendChild(a);r.appendChild(b);return r;}
function clr(id){var e=document.getElementById(id);e.textContent='';return e;}
function rDec(d){var b=clr('c-dec');var e=d.decoder||{};b.appendChild(row('SDK Ready',e.ready?'Yes':'No',e.ready?'a':'d'));b.appendChild(row('Device (Aura-M)',e.deviceId||'—','mono'));if(e.track){var p=row('Now Playing','▶ '+e.track);p.querySelector('.v').style.color='#1db954';b.appendChild(p);b.appendChild(row('Artist',e.artist));b.appendChild(row('Position',Math.floor(e.position)+'s / '+Math.floor(e.duration)+'s'));}else b.appendChild(row('Playback',e.paused===false?'playing':'idle'));}
function rAuth(d){var b=clr('c-auth');var a=d.auth||{};b.appendChild(row('Harness Token',a.tokenPresent?'Present':'Missing',a.tokenPresent?'a':'d'));b.appendChild(row('Rides Spotty acct',a.spottyAccount||'—','mono'));}
function rSvc(d){var b=clr('c-svc');var s=d.services||[];var up=0;s.forEach(function(x){if(x.alive)up++;});b.appendChild(row('Active',up+' / '+s.length,up===s.length?'a':'w'));b.appendChild(document.createElement('hr'));s.forEach(function(x){var r=document.createElement('div');r.className='r';var l=document.createElement('span');l.className='l';var dot=document.createElement('span');dot.className=x.alive?'a':'d';dot.textContent='● ';l.appendChild(dot);l.appendChild(document.createTextNode(x.name.replace('spotify-','')));var v=document.createElement('span');v.className='v muted';v.textContent=x.alive?fUp(x.uptime):x.active;r.appendChild(l);r.appendChild(v);b.appendChild(r);});}
function rSys(d){var b=clr('c-sys');var s=d.system||{};b.appendChild(row('Version',s.version?'v'+s.version:'—'));b.appendChild(row('LMS',s.lms?'reachable':'down',s.lms?'a':'d'));b.appendChild(row('Loopback (snd-aloop)',s.loopback?'present':'MISSING',s.loopback?'a':'d'));b.appendChild(row('Hub :8790',s.hub?'serving':'down',s.hub?'a':'d'));b.appendChild(row('Spotty wiring',s.spottyWired?'installed':'NOT wired',s.spottyWired?'a':'w'));b.appendChild(document.createElement('hr'));b.appendChild(row('Decode engine',s.decodeEngine||'—'));b.appendChild(row('librespot outage','immune','a'));}
function rErr(d){var b=clr('c-err');var es=d.errors||[];if(!es.length){var m=document.createElement('div');m.className='muted';m.textContent='No errors recorded.';b.appendChild(m);return;}es.forEach(function(e){var r=document.createElement('div');r.className='er';var lo=(e.message||'').toLowerCase();if(/error|fail|denied|invalid/.test(lo))r.className+=' e';else r.className+=' wn';var mod=document.createElement('span');mod.className='em';mod.textContent='['+(e.module||'')+']';r.appendChild(mod);var msg=document.createElement('span');msg.className='emsg';msg.textContent=e.message||'';r.appendChild(msg);b.appendChild(r);});}
function render(d){if(d.error){document.getElementById('eb').style.display='block';document.getElementById('eb').textContent=d.error;return;}rDec(d);rAuth(d);rSvc(d);rSys(d);rErr(d);}
var t;function poll(){var x=new XMLHttpRequest();x.timeout=8000;x.open('GET','/plugins/AuraSpotifyStatus/data',true);x.onload=function(){if(x.status===200){try{render(JSON.parse(x.responseText));document.getElementById('eb').style.display='none';var i=document.getElementById('pi');i.style.opacity='1';setTimeout(function(){i.style.opacity='0.7';},200);document.getElementById('lu').textContent='Updated: '+new Date().toLocaleTimeString();}catch(e){document.getElementById('eb').style.display='block';}}else document.getElementById('eb').style.display='block';t=setTimeout(poll,5000);};x.ontimeout=x.onerror=function(){document.getElementById('eb').style.display='block';t=setTimeout(poll,5000);};x.send();}
document.addEventListener('visibilitychange',function(){if(document.hidden)clearTimeout(t);else{clearTimeout(t);poll();}});poll();
</script></body></html>
HTML
}

1;
