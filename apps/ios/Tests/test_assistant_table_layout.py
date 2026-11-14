"""Exercise the shared, measured mobile reply layout in a real headless browser."""
import html
import json
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]


def chrome_path():
    for candidate in [shutil.which("google-chrome"), shutil.which("chromium"),
                      r"C:\Program Files\Google\Chrome\Application\chrome.exe",
                      r"C:\Program Files (x86)\Google\Chrome\Application\chrome.exe",
                      "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"]:
        if candidate and Path(candidate).is_file():
            return candidate
    return None


def presentation():
    source = (ROOT / "Hako/Shared/UI/AssistantTableLayout.swift").read_text(encoding="utf-8")
    script = re.search(r'static let script = #"""(.*?)"""#', source, re.S)[1]
    style = re.search(r'static let style = """(.*?)"""', source, re.S)[1]
    renderer = (ROOT / "Hako/Shared/UI/AssistantReplyView.swift").read_text(encoding="utf-8")
    base = renderer.split("<style>", 1)[1].split("</style>", 1)[0]
    font_size = re.search(r"private var fontSize = ([\d.]+)", renderer)[1]
    base = base.replace(r'\(dark ? "dark" : "light")', "light").replace(r"\(fontSize)", font_size)
    for name, color in {"text": "#202124", "muted": "#76777d", "card": "#ffffff", "background": "#f5f5f7", "line": "#e9e9ee"}.items():
        base = base.replace(r"\(css(HakoStyle." + name + "))", color)
    base = base.replace(r"\(css(HakoStyle.adaptive(0xf6f6f8, 0x2b2b2f)))", "#f6f6f8")
    return base.replace(r"\(AssistantTableLayout.style)", style), script


def fixtures():
    wrapping = "说明文字需要完整显示并根据手机的实际可用宽度决定排版方式，不能把较长的内容挤在狭窄的列中造成大量换行。"
    return [
        ("short", 320, "<table><tr><th>项目</th><th>数量</th></tr><tr><td>甲</td><td>12</td></tr><tr><td>乙</td><td>34</td></tr></table>"),
        ("columns", 390, "<table><caption>执行统计</caption><thead><tr><th>名称</th><th>状态</th><th>时间</th><th>次数</th></tr></thead><tbody><tr><td>任务甲</td><td>完成</td><td>12:00</td><td>3</td></tr></tbody><tfoot><tr><th>合计</th><th>完成</th><th>今日</th><th>3</th></tr></tfoot></table>"),
        ("long", 390, "<table><tr><th>名称</th><th>说明</th></tr><tr><td><code>example.py</code></td><td>" + "长内容" * 40 + "</td></tr></table>"),
        ("breaks", 390, "<table><tr><th>名称</th><th>内容</th></tr><tr><td>分行</td><td>一<br>二<br>三<br>四</td></tr></table>"),
        ("narrow", 280, "<table><tr><th>项目</th><th>说明</th></tr><tr><td>甲</td><td>" + wrapping + "</td></tr></table>"),
        ("wide", 1000, "<table><tr><th>项目</th><th>说明</th></tr><tr><td>甲</td><td>" + wrapping + "</td></tr></table>"),
        ("headerless", 320, "<table><tr><td>甲</td><td>乙</td><td>丙</td><td>丁</td></tr></table>"),
        ("nested", 320, "<table><tr><td>外层</td><td><table><tr><td>内层甲</td><td>内层乙</td><td>内层丙</td><td>内层丁</td></tr></table></td></tr></table>"),
        ("typography", 320, "<h2>说明标题</h2><h3><code>file.js</code></h3><p>正文 <code>HTTP_PROXY</code></p>"),
    ]


def document():
    style, script = presentation()
    content = "".join(f'<section id="{name}" style="width:{width}px">{table}</section>' for name, width, table in fixtures())
    checks = """
        const ids = ['short', 'columns', 'long', 'breaks', 'narrow', 'wide', 'headerless', 'nested'];
        const result = {};
        for (const id of ids) {
            const element = document.getElementById(id);
            result[id] = {
                tables: element.querySelectorAll('table').length,
                lists: element.querySelectorAll('.assistant-table-list').length,
                labels: Array.from(element.querySelectorAll('.assistant-table-label'), node => node.textContent),
                values: Array.from(element.querySelectorAll('.assistant-table-value'), node => node.textContent),
                caption: element.querySelector('.assistant-table-caption')?.textContent,
                overflow: element.scrollWidth > element.clientWidth + 1
            };
        }
    """
    type_checks = """
        function typography() {
            const section = document.getElementById('typography');
            const title = document.querySelector('#long .assistant-table-title .assistant-table-value');
            const label = document.querySelector('#long .assistant-table-label');
            const read = (node, property) => parseFloat(getComputedStyle(node)[property]);
            return {
                body: read(section.querySelector('p'), 'fontSize'),
                line: read(section.querySelector('p'), 'lineHeight'),
                heading: read(section.querySelector('h2'), 'fontSize'),
                title: read(title, 'fontSize'),
                label: read(label, 'fontSize'),
                titleCode: read(title.querySelector('code'), 'fontSize'),
                headingCode: read(section.querySelector('h3 code'), 'fontSize'),
                inlineCode: read(section.querySelector('p code'), 'fontSize'),
                fieldGap: read(document.querySelector('#long .assistant-table-field + .assistant-table-field'), 'marginTop'),
                itemGap: read(document.querySelector('#columns .assistant-table-list > li + li'), 'marginTop')
            };
        }
        result.typography = typography();
        const size = getComputedStyle(document.documentElement).fontSize;
        document.documentElement.style.fontSize = (parseFloat(size) * 2) + 'px';
        result.enlargedTypography = typography();
        document.documentElement.style.fontSize = size;
    """
    return '<!doctype html><meta charset="utf-8"><style>' + style + '</style><main>' + content + '</main><script>' + script + ';' + checks + type_checks + 'result.secondPass = ' + script + ';document.body.append(Object.assign(document.createElement("pre"), {id:"layout-test-result", textContent:JSON.stringify(result)}));</script>'


@unittest.skipUnless(chrome_path(), "Headless Chrome is required for measured layout tests")
class AssistantTableLayoutTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        with tempfile.TemporaryDirectory(prefix="hako-table-layout-") as directory:
            directory = Path(directory)
            page = directory / "layout.html"
            page.write_text(document(), encoding="utf-8")
            process = subprocess.run([chrome_path(), "--headless=new", "--disable-gpu", "--no-sandbox",
                                      "--no-first-run", "--no-default-browser-check", "--window-size=410,1000",
                                      f"--user-data-dir={directory / 'profile'}", "--dump-dom", page.as_uri()],
                                     capture_output=True, text=True, encoding="utf-8", timeout=45)
            match = re.search(r'<pre id="layout-test-result">([^<]+)</pre>', process.stdout)
            if process.returncode or not match:
                raise AssertionError(process.stderr[-2000:] + process.stdout[-1000:])
            cls.result = json.loads(html.unescape(match[1]))

    def test_short_table_stays_compact(self):
        self.assertEqual(self.result["short"]["tables"], 1)
        self.assertEqual(self.result["short"]["lists"], 0)

    def test_many_columns_preserve_labels_caption_and_footer(self):
        result = self.result["columns"]
        self.assertEqual(result["tables"], 0)
        self.assertEqual(result["caption"], "执行统计")
        self.assertEqual(result["labels"], ["名称", "状态", "时间", "次数"] * 2)
        self.assertEqual(result["values"], ["任务甲", "完成", "12:00", "3", "合计", "完成", "今日", "3"])

    def test_long_and_multiline_cells_use_lists(self):
        for name in ["long", "breaks"]:
            with self.subTest(name=name):
                self.assertEqual(self.result[name]["tables"], 0)
                self.assertEqual(self.result[name]["lists"], 1)
                self.assertFalse(self.result[name]["overflow"])
        self.assertIn("example.py", self.result["long"]["values"])

    def test_actual_available_width_controls_wrapping(self):
        self.assertEqual(self.result["narrow"]["tables"], 0)
        self.assertEqual(self.result["wide"]["tables"], 1)

    def test_headerless_and_nested_tables_keep_all_content(self):
        self.assertEqual(self.result["headerless"]["values"], ["甲", "乙", "丙", "丁"])
        for text in ["外层", "内层甲", "内层乙", "内层丙", "内层丁"]:
            self.assertIn(text, "".join(self.result["nested"]["values"]))

    def test_repeated_layout_does_not_duplicate_lists(self):
        self.assertEqual(self.result["secondPass"], 0)

    def test_type_hierarchy_and_dynamic_scaling(self):
        expected = {"body": 14, "line": 21, "heading": 17, "title": 17, "label": 12,
                    "titleCode": 16, "headingCode": 16, "inlineCode": 13, "fieldGap": 8, "itemGap": 16}
        for name, value in expected.items():
            with self.subTest(name=name):
                self.assertAlmostEqual(self.result["typography"][name], value, places=2)
                self.assertAlmostEqual(self.result["enlargedTypography"][name], value * 2, places=2)


if __name__ == "__main__":
    unittest.main()
