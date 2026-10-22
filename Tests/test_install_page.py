import importlib.util
import datetime
import json
import plistlib
import tempfile
import re
import unittest
import zipfile
from pathlib import Path

spec = importlib.util.spec_from_file_location('install_page', Path(__file__).resolve().parents[1] / 'scripts/build-install-page.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

class InstallPageTests(unittest.TestCase):
    def test_ota_artifact(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            ipa = root / 'Hako.ipa'
            with zipfile.ZipFile(ipa, 'w') as archive:
                archive.writestr('Payload/Hako.app/Info.plist', plistlib.dumps({'CFBundleIdentifier':'me.stackli.hako','CFBundleVersion':'42','CFBundleShortVersionString':'1.0','MinimumOSVersion':'26.4'}))
            output = root / 'site'
            module.build(ipa, 'https://example.github.io/hako/', output)
            manifest_path = next(output.glob('manifest-*.plist'))
            item = plistlib.loads(manifest_path.read_bytes())['items'][0]
            self.assertEqual((output / 'manifest.plist').read_bytes(), manifest_path.read_bytes())
            self.assertEqual(item['metadata']['bundle-version'], '42')
            filename = item['assets'][0]['url'].rsplit('/', 1)[1]
            self.assertEqual((output / filename).read_bytes(), ipa.read_bytes())
            self.assertTrue(item['assets'][0]['url'].startswith('https://example.github.io/hako/'))
            page = (output / 'index.html').read_text()
            self.assertNotIn('{{', page)
            timestamp = re.search(r'<time id="build-time" datetime="([^"]+)">([^<]+)</time>', page)
            self.assertIsNotNone(timestamp)
            built_at = datetime.datetime.fromisoformat(timestamp[1])
            self.assertEqual(built_at.utcoffset(), datetime.timedelta(0))
            self.assertEqual(timestamp[2], built_at.strftime('%Y-%m-%d %H:%M UTC'))
            release = json.loads((output / 'latest.json').read_text(encoding='utf-8'))
            self.assertEqual(datetime.datetime.fromisoformat(release['builtAt']), built_at)
            self.assertEqual(release['version'], '1.0')
            self.assertEqual(release['build'], '42')
            self.assertIn('itms-services://?action=download-manifest&amp;url=https%3A%2F%2Fexample.github.io%2Fhako%2Fmanifest-', page)
            with self.assertRaises(ValueError):
                module.build(ipa, 'http://example.com', output)

if __name__ == '__main__':
    unittest.main()
