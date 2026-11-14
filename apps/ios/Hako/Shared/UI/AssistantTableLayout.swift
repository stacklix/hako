// Trusted presentation code runs in WebKit's isolated client world. Model HTML
// stays sanitized, with page JavaScript, external resources and navigation disabled.
enum AssistantTableLayout {
    static let style = """
        .assistant-table-list { list-style: none; margin: 0 0 var(--title-gap); padding: 0; }
        .assistant-table-list > li + li { margin-top: var(--item-gap); padding-top: var(--item-gap); border-top: 1px solid var(--line); }
        .assistant-table-field + .assistant-table-field { margin-top: var(--title-gap); }
        .assistant-table-label { display: block; margin-bottom: var(--field-gap); color: var(--muted); font-size: var(--label-size); }
        .assistant-table-value { min-width: 0; overflow-wrap: anywhere; }
        .assistant-table-title .assistant-table-value { font-size: var(--title-size); line-height: 1.4; font-weight: 600; }
        .assistant-table-title .assistant-table-value code { font-size: var(--title-code-size); }
        .assistant-table-value > :first-child { margin-top: 0; }
        .assistant-table-value > :last-child { margin-bottom: 0; }
        .assistant-table-caption { margin-bottom: var(--title-gap); font-size: var(--title-size); line-height: 1.4; font-weight: 600; }
        """

    static let script = #"""
        (() => {
            function lineCount(cell) {
                const walker = document.createTreeWalker(cell, NodeFilter.SHOW_TEXT);
                const tops = [];
                const range = document.createRange();
                while (walker.nextNode()) {
                    if (!walker.currentNode.textContent.trim()) continue;
                    range.selectNodeContents(walker.currentNode);
                    for (const rect of range.getClientRects()) {
                        if (rect.width > 0 && rect.height > 0) tops.push(rect.top);
                    }
                }
                const spacing = (parseFloat(getComputedStyle(cell).lineHeight) || 20) * .5;
                tops.sort((a, b) => a - b);
                let lines = 0, previous = -Infinity;
                for (const top of tops) {
                    if (top - previous > spacing) { lines++; previous = top; }
                }
                return lines;
            }
            let converted = 0;
            for (const table of Array.from(document.querySelectorAll('table')).reverse()) {
                // Only direct rows/cells belong to this table; nested content is preserved.
                if (!table.isConnected) continue;
                const rows = Array.from(table.rows).filter(row => row.closest('table') === table);
                if (!rows.length) continue;
                const columns = Math.max(...rows.map(row => row.cells.length));
                const cells = rows.flatMap(row => Array.from(row.cells));
                const crowded = columns >= 4 || cells.some(cell =>
                    cell.textContent.trim().length >= 96 || lineCount(cell) > 3 ||
                    cell.scrollWidth > cell.clientWidth + 1) || table.scrollWidth > table.clientWidth + 1;
                if (!crowded) continue;
                const isHeader = row => row.cells.length > 0 && Array.from(row.cells).every(cell => cell.tagName === 'TH');
                const headerRows = rows.filter(row => row.parentElement.tagName === 'THEAD');
                if (!headerRows.length && rows[0].parentElement.tagName !== 'TFOOT' && isHeader(rows[0])) headerRows.push(rows[0]);
                const header = headerRows[headerRows.length - 1];
                const labels = header ? Array.from(header.cells, cell => cell.textContent.trim()) : [];
                const records = rows.filter(row => !headerRows.includes(row));
                if (!records.length) continue;
                const block = document.createElement('div');
                if (table.caption) {
                    const caption = document.createElement('p');
                    caption.className = 'assistant-table-caption';
                    for (const node of table.caption.childNodes) caption.append(node.cloneNode(true));
                    block.append(caption);
                }
                const list = document.createElement('ul');
                list.className = 'assistant-table-list';
                for (const row of records) {
                    const item = document.createElement('li');
                    Array.from(row.cells).forEach((cell, index) => {
                        const field = document.createElement('div');
                        field.className = 'assistant-table-field' + (index === 0 ? ' assistant-table-title' : '');
                        if (labels[index]) {
                            const label = document.createElement('small');
                            label.className = 'assistant-table-label';
                            label.textContent = labels[index];
                            field.append(label);
                        }
                        const value = document.createElement('div');
                        value.className = 'assistant-table-value';
                        for (const node of cell.childNodes) value.append(node.cloneNode(true));
                        field.append(value);
                        item.append(field);
                    });
                    list.append(item);
                }
                block.append(list);
                table.replaceWith(block);
                converted++;
            }
            return converted;
        })()
        """#
}
