#!/bin/bash
# Builds an INSTALLABLE S3 OS image (Debian base + S3 desktop + Calamares disk installer).
# Boot the USB -> S3 OS desktop -> Start > "Install S3 OS..." -> installs to the computer's disk.
# Run as root on a real Debian/Ubuntu machine or VM (NOT WSL1). Needs ~15 GB free + internet.
# Usage: sudo ./build-s3os-iso.sh   (keep s3-os.html in the same folder)
set -e
[ "$(id -u)" = 0 ] || { echo "Run as root (sudo)"; exit 1; }
HERE="$(cd "$(dirname "$0")" && pwd)"
[ -f "$HERE/s3-os.html" ] || { echo "s3-os.html not found next to this script"; exit 1; }
apt-get update && apt-get install -y live-build debootstrap squashfs-tools xorriso debian-archive-keyring

WORK=/root/s3os-build
rm -rf "$WORK"; mkdir -p "$WORK"; cd "$WORK"

lb config \
  --distribution bookworm --architectures amd64 \
  --archive-areas "main contrib non-free-firmware" \
  --binary-images iso-hybrid --debian-installer none \
  --bootappend-live "boot=live components quiet splash hostname=s3os" \
  --iso-application "S3 OS" --iso-volume "S3OS" --memtest none

mkdir -p config/package-lists config/hooks/normal config/includes.chroot/opt/s3os config/includes.chroot/etc/systemd/system
cat > config/package-lists/s3os.list.chroot <<'EOF'
cage
chromium
qtwayland5
dbus-user-session
libpam-systemd
calamares
calamares-settings-debian
grub-efi-amd64
grub-pc-bin
shim-signed
efibootmgr
python3
sudo
network-manager
pipewire-audio
firmware-linux
fonts-noto-core
fonts-noto-color-emoji
fonts-dejavu-core
EOF

cp "$HERE/s3-os.html" config/includes.chroot/opt/s3os/index.html

# Tiny local helper: lets the desktop's Start menu start the installer, restart and shut down.
cat > config/includes.chroot/opt/s3os/helper.py <<'HELPEREOF'
#!/usr/bin/env python3
# S3 OS helper: system actions (install/restart/shut down) + a small web proxy for the Browser app.
import os, subprocess, json, html, urllib.request, urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

UA = 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120 Safari/537.36'
INJ = """<base href="@@BASE@@"><script>(function(){var P='http://127.0.0.1:8765/proxy?u=',O=@@URL@@;
try{parent.postMessage({s3url:O},'*')}catch(e){}
document.addEventListener('click',function(e){var a=e.target.closest&&e.target.closest('a');
if(!a||!a.href||a.href.indexOf('http')!=0)return;e.preventDefault();location.href=P+encodeURIComponent(a.href)},true);
document.addEventListener('submit',function(e){var f=e.target;if((f.method||'get').toLowerCase()!='get')return;
e.preventDefault();var u=new URL(f.action||O,O);new FormData(f).forEach(function(v,k){u.searchParams.set(k,v)});
location.href=P+encodeURIComponent(u.href)},true)})();</script>"""

class H(BaseHTTPRequestHandler):
    def reply(s, code, body=b'', ct='text/plain'):
        s.send_response(code)
        s.send_header('Access-Control-Allow-Origin', '*')
        s.send_header('Content-Type', ct)
        s.send_header('Content-Length', str(len(body)))
        s.end_headers()
        s.wfile.write(body)

    def do_GET(s):
        p = s.path
        if p == '/ping':
            return s.reply(200, b'ok')
        if p.startswith('/proxy?'):
            u = urllib.parse.parse_qs(urllib.parse.urlparse(p).query).get('u', [''])[0]
            if not u.startswith(('http://', 'https://')):
                return s.reply(400, b'Bad address')
            try:
                r = urllib.request.urlopen(urllib.request.Request(u, headers={'User-Agent': UA, 'Accept-Language': 'en'}), timeout=20)
                body = r.read(); ct = r.headers.get('Content-Type', 'text/html'); final = r.geturl()
            except Exception as e:
                msg = '<body style="font:15px sans-serif;padding:30px"><h3>Could not load this page</h3><p>%s</p>' % html.escape(str(e))
                return s.reply(200, msg.encode(), 'text/html; charset=utf-8')
            if 'text/html' in ct:
                t = body.decode(r.headers.get_content_charset() or 'utf-8', 'replace')
                inj = INJ.replace('@@BASE@@', html.escape(final, quote=True)).replace('@@URL@@', json.dumps(final).replace('</', '<\\/'))
                i = t.lower().find('<head')
                if i >= 0:
                    j = t.find('>', i) + 1
                    t = t[:j] + inj + t[j:]
                else:
                    t = inj + t
                body = t.encode('utf-8'); ct = 'text/html; charset=utf-8'
            return s.reply(200, body, ct)
        cmd = None
        if p == '/install' and os.path.isdir('/run/live/medium'):
            cmd = ['systemctl', 'start', '--no-block', 's3os-install.service']
        elif p == '/reboot':
            cmd = ['systemctl', 'reboot']
        elif p == '/poweroff':
            cmd = ['systemctl', 'poweroff']
        if not cmd:
            return s.reply(404, b'no')
        s.reply(200, b'ok')
        subprocess.Popen(cmd)

    def log_message(s, *a): pass

ThreadingHTTPServer(('127.0.0.1', 8765), H).serve_forever()
HELPEREOF

cat > config/includes.chroot/etc/systemd/system/s3os-helper.service <<'EOF'
[Unit]
Description=S3 OS system helper
[Service]
ExecStart=/usr/bin/python3 /opt/s3os/helper.py
Restart=always
[Install]
WantedBy=multi-user.target
EOF

# The desktop: full-screen Chromium inside the cage kiosk compositor, on screen 1
cat > config/includes.chroot/etc/systemd/system/s3os.service <<'EOF'
[Unit]
Description=S3 OS desktop
After=systemd-user-sessions.service getty@tty1.service
Conflicts=getty@tty1.service s3os-install.service
[Service]
User=s3kiosk
PAMName=login
TTYPath=/dev/tty1
TTYReset=yes
TTYVHangup=yes
TTYVTDisallocate=yes
StandardInput=tty-fail
UtmpIdentifier=tty1
UtmpMode=user
Environment=XDG_SESSION_TYPE=wayland
Environment=WLR_RENDERER_ALLOW_SOFTWARE=1
ExecStart=/usr/bin/cage -s -- /usr/bin/chromium --ozone-platform=wayland --kiosk --noerrdialogs --disable-infobars --no-first-run --user-data-dir=/home/s3kiosk/.s3 file:///opt/s3os/index.html
Restart=always
[Install]
WantedBy=multi-user.target
EOF

# The disk installer (Calamares), started from Start > Install S3 OS...
cat > config/includes.chroot/etc/systemd/system/s3os-install.service <<'EOF'
[Unit]
Description=S3 OS installer
Conflicts=s3os.service getty@tty1.service
After=getty@tty1.service
[Service]
Type=simple
TTYPath=/dev/tty1
TTYReset=yes
TTYVHangup=yes
StandardInput=tty-fail
Environment=XDG_RUNTIME_DIR=/run/user/0
Environment=LIBSEAT_BACKEND=builtin
Environment=WLR_RENDERER_ALLOW_SOFTWARE=1
Environment=QT_QPA_PLATFORM=wayland
ExecStartPre=/usr/bin/install -d -m 0700 /run/user/0
ExecStart=/usr/bin/cage -s -- /usr/bin/calamares
EOF

cat > config/hooks/normal/0100-s3os.hook.chroot <<'EOF'
#!/bin/sh
useradd -m -s /usr/sbin/nologin -G video,audio,input,render s3kiosk || useradd -m -s /usr/sbin/nologin -G video,audio,input s3kiosk
systemctl enable s3os.service s3os-helper.service
systemctl set-default multi-user.target
EOF
chmod +x config/hooks/normal/0100-s3os.hook.chroot

lb build
cp live-image-amd64.hybrid.iso "$HERE/S3-OS.iso"
sha256sum "$HERE/S3-OS.iso"
echo
echo "ISO ready: $WORK/live-image-amd64.hybrid.iso"
echo "1) Test in a VM first (VirtualBox, or: qemu-system-x86_64 -m 2048 -enable-kvm -cdrom <iso> -hda test.img after: qemu-img create test.img 20G)"
echo "2) Write to USB with Rufus (DD mode) or balenaEtcher, boot the new PC from USB,"
echo "   then Start > Install S3 OS... Installing ERASES the disk you choose in the installer."
