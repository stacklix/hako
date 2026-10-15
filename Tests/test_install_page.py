import importlib.util
import plistlib
import tempfile
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
            self.assertEqual(item['metadata']['bundle-version'], '42')
            filename = item['assets'][0]['url'].rsplit('/', 1)[1]
            self.assertEqual((output / filename).read_bytes(), ipa.read_bytes())
            self.assertTrue(item['assets'][0]['url'].startswith('https://example.github.io/hako/'))
            page = (output / 'index.html').read_text()
            self.assertNotIn('{{', page)
            self.assertIn('itms-services://?action=download-manifest&amp;url=https%3A%2F%2Fexample.github.io%2Fhako%2Fmanifest-', page)
            with self.assertRaises(ValueError):
                module.build(ipa, 'http://example.com', output)

if __name__ == '__main__':
    unittest.main()
