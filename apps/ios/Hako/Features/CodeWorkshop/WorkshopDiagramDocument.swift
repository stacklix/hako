import Foundation

enum WorkshopDiagramDocument {
    static func supports(_ language: String?) -> Bool {
        language?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "mermaid"
    }

    static func build(source: String, library: String, dark: Bool, nonce: String) -> String {
        let encoded = Data(source.utf8).base64EncodedString()
        let script = library.replacingOccurrences(of: "</script", with: "<\\/script", options: .caseInsensitive)
        return """
        <!doctype html><html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'nonce-\(nonce)'; style-src 'unsafe-inline'; img-src data:; base-uri 'none'; form-action 'none'; connect-src 'none'">
        <style>
        :root { color-scheme: \(dark ? "dark" : "light"); font: -apple-system-body; }
        body { margin:0; padding:12px; color:\(dark ? "#f2f2f4" : "#202124"); background:transparent; }
        #chart { display:flex; justify-content:center; width:max-content; min-width:100%; }
        #chart svg { max-width:none !important; height:auto; }
        #failure { white-space:pre-wrap; font-size:14px; line-height:1.5; }
        </style></head><body><div id="chart"></div><div id="failure" role="status">正在生成图表…</div>
        <script nonce="\(nonce)">\(script)</script>
        <script nonce="\(nonce)">
        const send = value => window.webkit?.messageHandlers.diagram?.postMessage(value);
        let naturalWidth = 320;
        window.diagramZoom = function(scale, fit) {
          const svg = document.querySelector('#chart svg'); if (!svg) return;
          const width = fit ? Math.max(200, innerWidth - 24) : Math.max(320, naturalWidth);
          svg.style.width = (Math.min(4000, width * scale)) + 'px';
          send({height: Math.ceil(document.body.scrollHeight)});
        };
        (async () => {
          try {
            const source = new TextDecoder().decode(Uint8Array.from(atob('\(encoded)'), c => c.charCodeAt(0)));
            if (source.length > 60000) throw new Error('图表内容过长，请查看源码。');
            mermaid.initialize({startOnLoad:false, securityLevel:'strict', theme:'\(dark ? "dark" : "default")',
              suppressErrorRendering:true, maxTextSize:60000, maxEdges:500,
              secure:['securityLevel','startOnLoad','maxTextSize','maxEdges','suppressErrorRendering'],
              flowchart:{htmlLabels:false, useMaxWidth:false}});
            const result = await mermaid.render('workshop-diagram', source);
            document.getElementById('chart').innerHTML = result.svg;
            // Diagrams are read-only. No embedded URL, command or node action can navigate.
            document.querySelectorAll('#chart a').forEach(a => { a.removeAttribute('href'); a.removeAttribute('xlink:href'); });
            const svg = document.querySelector('#chart svg');
            naturalWidth = svg.viewBox.baseVal.width || 320;
            document.getElementById('failure').textContent = '';
            window.diagramZoom(1, false);
            send({ready:true});
          } catch (error) {
            document.getElementById('chart').replaceChildren();
            document.getElementById('failure').textContent = '图表无法渲染，请切换源码检查 Mermaid 语法。';
            send({error:true, height:100});
          }
        })();
        </script></body></html>
        """
    }
}
