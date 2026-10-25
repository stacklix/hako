#!/usr/bin/env python3
"""Generate a self-contained GitHub Pages OTA installation artifact from an IPA."""
import argparse
import datetime
import hashlib
import html
import json
import plistlib
import shutil
import urllib.parse
import zipfile
from pathlib import Path


def build(ipa, base_url, output):
    parsed = urllib.parse.urlsplit(base_url)
    if parsed.scheme != 'https' or not parsed.netloc or parsed.query or parsed.fragment:
        raise ValueError('Pages URL must be an absolute HTTPS URL without query or fragment')
    with zipfile.ZipFile(ipa) as archive:
        names = [n for n in archive.namelist() if n.startswith('Payload/') and n.count('/') == 2 and n.endswith('.app/Info.plist')]
        if len(names) != 1:
            raise ValueError('Expected exactly one app in IPA')
        info = plistlib.loads(archive.read(names[0]))
    if info['CFBundleIdentifier'] != 'me.stackli.hako':
        raise ValueError('Expected Hako IPA')
    digest = hashlib.sha256(ipa.read_bytes()).hexdigest()[:16]
    filename = f'Hako-{digest}.ipa'
    manifest_name = f'manifest-{digest}.plist'
    base_url = base_url.rstrip('/')
    ipa_url = f'{base_url}/{filename}'
    manifest_url = f'{base_url}/{manifest_name}'
    install_url = 'itms-services://?action=download-manifest&url=' + urllib.parse.quote(manifest_url, safe='')
    output.mkdir(parents=True, exist_ok=True)
    shutil.copy2(ipa, output / filename)
    manifest = {'items': [{'assets': [{'kind': 'software-package', 'url': ipa_url}], 'metadata': {
        'bundle-identifier': info['CFBundleIdentifier'], 'bundle-version': str(info['CFBundleVersion']),
        'kind': 'software', 'title': 'Hako'}}]}
    (output / manifest_name).write_bytes(plistlib.dumps(manifest))
    # Stable entry point for installed apps; the IPA URL remains content-addressed.
    (output / 'manifest.plist').write_bytes(plistlib.dumps(manifest))
    template = Path(__file__).resolve().parent.parent / 'distribution/install.html'
    page = template.read_text()
    built_at = datetime.datetime.now(datetime.timezone.utc)
    (output / 'latest.json').write_text(json.dumps({
        'builtAt': built_at.isoformat(timespec='seconds'),
        'version': str(info.get('CFBundleShortVersionString', '1.0')),
        'build': str(info['CFBundleVersion'])
    }), encoding='utf-8')
    values = {'INSTALL_URL': install_url, 'IPA_URL': ipa_url,
              'VERSION': str(info.get('CFBundleShortVersionString', '1.0')),
              'BUILD': str(info['CFBundleVersion']), 'MIN_IOS': str(info.get('MinimumOSVersion', '26.4')),
              'DATE_ISO': built_at.isoformat(timespec='seconds'),
              'DATE': built_at.strftime('%Y-%m-%d %H:%M UTC')}
    for key, value in values.items():
        page = page.replace('{{'+key+'}}', html.escape(value, quote=True))
    (output / 'index.html').write_text(page)
    (output / '.nojekyll').touch()


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--ipa', required=True, type=Path)
    parser.add_argument('--url', required=True)
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    build(args.ipa, args.url, args.output)
