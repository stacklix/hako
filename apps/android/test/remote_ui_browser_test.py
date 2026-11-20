"""Check the built UI using an isolated headless Chrome profile, with no HTTP server.

Run npm run build:remote first, then python test/remote_ui_browser_test.py.
Set CHROME_BIN if Chrome is not at the default Windows installation path.
Use --screenshots for visual QA; output follows the local screenshot convention.
"""
from datetime import datetime
import html
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import uuid

root = Path(__file__).resolve().parents[1]
assets = root / 'android/app/src/main/assets/remote'
repo = root.parents[1]
test_dir = repo / '.test-tmp/nami-remote-ui'
test_dir.mkdir(parents=True, exist_ok=True)
chrome = os.environ.get('CHROME_BIN', r'C:\Program Files\Google\Chrome\Application\chrome.exe')
index = (assets / 'index.html').read_text(encoding='utf-8')
script = re.search(r'src="/remote/([^"]+\.js)"', index).group(1)
stylesheet = re.search(r'href="/remote/([^"]+\.css)"', index).group(1)
# A fixture public key, never used for authentication. No private key is created.
pem = '-----BEGIN PUBLIC KEY-----\n' + '\n'.join(['A' * 64] * 9) + '\n-----END PUBLIC KEY-----'
checks = (root / 'test/remote_ui_browser_checks.js').read_text(encoding='utf-8')
bundle = (assets / script).read_text(encoding='utf-8').replace('</script', '<\\/script')
css = (assets / stylesheet).read_text(encoding='utf-8')
document = '<!doctype html><html lang="zh-CN"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><style>' + css + '</style><div id="root"></div><script>window.__testPublicKey=' + json.dumps(pem) + ';window.__requestedWidth=REQUESTED_WIDTH;' + checks + '</script><script type="module">' + bundle + '</script></html>'
page = test_dir / 'production-ui-check.html'

def write_page(width, capture=''):
    # Chrome has a minimum top-level window width on Windows. An iframe gives the
    # app an exact viewport, including 320px, independently of that window limit.
    child = document.replace('REQUESTED_WIDTH', str(width)).replace("new URL(location.href).searchParams.get('capture')", json.dumps(capture))
    wrapper = f'<!doctype html><meta charset="utf-8"><style>body{{margin:0}}iframe{{display:block;border:0;width:{width}px;height:1000px}}</style><iframe srcdoc="{html.escape(child, quote=True)}"></iframe>'
    page.write_text(wrapper, encoding='utf-8')
flags = ['--headless', '--no-sandbox', '--disable-gpu', '--disable-software-rasterizer', '--disable-gpu-sandbox', '--no-first-run', '--no-default-browser-check', '--allow-file-access-from-files', '--hide-scrollbars', '--run-all-compositor-stages-before-draw']

if '--screenshots' in sys.argv:
    image_dir = Path.home() / '.chore/public/images' / datetime.now().strftime('%Y%m%d')
    image_dir.mkdir(parents=True, exist_ok=True)
    for name, width in [('overview', 1056), ('connection', 1056), ('key', 1056), ('connection', 430)]:
        filename = datetime.now().strftime('%Y%m%d-%H%M%S-%f')[:19] + '-' + uuid.uuid4().hex[:6] + '-nami-' + name + '.png'
        target = image_dir / filename
        write_page(width, name)
        with tempfile.TemporaryDirectory(prefix='chrome-', dir=test_dir) as profile:
            subprocess.run([chrome, *flags, '--user-data-dir=' + profile, f'--window-size={width},1000', '--virtual-time-budget=4000', '--screenshot=' + str(target), page.as_uri() + '?capture=' + name], capture_output=True, timeout=60, check=True)
        print(target)
else:
    for width in [1056, 430, 320]:
        write_page(width)
        with tempfile.TemporaryDirectory(prefix='chrome-', dir=test_dir) as profile:
            result = subprocess.run([chrome, *flags, '--user-data-dir=' + profile, f'--window-size={width},1000', '--virtual-time-budget=12000', '--dump-dom', page.as_uri()], capture_output=True, timeout=60)
        dom = result.stdout.decode('utf-8', errors='replace')
        match = re.search(r'<pre id="qa-result">(.*?)</pre>', dom, re.S)
        if not match:
            (test_dir / f'failed-{width}.html').write_text(dom, encoding='utf-8')
            raise RuntimeError(f'No test results at width {width}; Chrome exit {result.returncode}')
        report = json.loads(html.unescape(match.group(1)))
        (test_dir / f'results-{width}.json').write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding='utf-8')
        if not report['ok']:
            print(json.dumps(report, ensure_ascii=False, indent=2)); sys.exit(1)
        print(f'{width}px: PASS ({len(report["checks"])} checks)')
