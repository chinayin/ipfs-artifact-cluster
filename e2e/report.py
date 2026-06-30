#!/usr/bin/env python3
"""把 e2e 的 manifest.jsonl 渲染成自包含 HTML 报告（单文件，无外链）。

用法: python3 report.py <RUN_DIR> [报告标题]
读取 <RUN_DIR>/manifest.jsonl（每行 {"status":"pass|fail|info","title":...}），
生成 <RUN_DIR>/report.html。可选第二参数自定义报告标题（默认部署 e2e 标题）。
"""
import json
import os
import sys
import html
from datetime import datetime

CSS = """
body{font:14px/1.6 -apple-system,Segoe UI,Roboto,Helvetica,Arial,sans-serif;margin:0;background:#f6f7f9;color:#1c2024}
.wrap{max-width:880px;margin:32px auto;padding:0 16px}
h1{font-size:20px;margin:0 0 4px}
.sub{color:#6b7280;font-size:13px;margin-bottom:20px}
.cards{display:flex;gap:12px;margin-bottom:20px;flex-wrap:wrap}
.card{flex:1;min-width:120px;background:#fff;border:1px solid #e5e7eb;border-radius:10px;padding:14px 16px}
.card .n{font-size:24px;font-weight:600}
.card .l{color:#6b7280;font-size:12px}
.ok{color:#16a34a}.bad{color:#dc2626}.dim{color:#6b7280}
.banner{display:inline-block;padding:4px 12px;border-radius:999px;font-weight:600;font-size:13px}
.banner.pass{background:#dcfce7;color:#166534}.banner.fail{background:#fee2e2;color:#991b1b}
table{width:100%;border-collapse:collapse;background:#fff;border:1px solid #e5e7eb;border-radius:10px;overflow:hidden}
th,td{text-align:left;padding:10px 14px;border-bottom:1px solid #f0f1f3;font-size:13px}
th{background:#fafafa;color:#6b7280;font-weight:600}
tr:last-child td{border-bottom:none}
.badge{display:inline-block;min-width:46px;text-align:center;padding:2px 8px;border-radius:6px;font-size:12px;font-weight:600}
.badge.pass{background:#dcfce7;color:#166534}
.badge.fail{background:#fee2e2;color:#991b1b}
.badge.info{background:#eef2f5;color:#6b7280}
"""


def main():
    if len(sys.argv) < 2:
        print("usage: report.py <RUN_DIR>", file=sys.stderr)
        return 2
    run = sys.argv[1]
    report_title = sys.argv[2] if len(sys.argv) > 2 else "IPFS Cluster 端到端测试报告"
    manifest = os.path.join(run, "manifest.jsonl")
    rows = []
    if os.path.exists(manifest):
        with open(manifest, encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if line:
                    rows.append(json.loads(line))

    npass = sum(1 for r in rows if r["status"] == "pass")
    nfail = sum(1 for r in rows if r["status"] == "fail")
    overall = "fail" if nfail else "pass"
    ts = datetime.now().strftime("%Y-%m-%d %H:%M:%S")

    trs = []
    for i, r in enumerate(rows, 1):
        st = r["status"]
        trs.append(
            f'<tr><td class="dim">{i}</td>'
            f'<td><span class="badge {st}">{st.upper()}</span></td>'
            f'<td>{html.escape(r["title"])}</td></tr>'
        )

    out = f"""<!doctype html><html lang="zh"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>{html.escape(report_title)}</title><style>{CSS}</style></head>
<body><div class="wrap">
<h1>{html.escape(report_title)}</h1>
<div class="sub">{ts} · <span class="banner {overall}">{overall.upper()}</span></div>
<div class="cards">
  <div class="card"><div class="n ok">{npass}</div><div class="l">通过</div></div>
  <div class="card"><div class="n {'bad' if nfail else 'dim'}">{nfail}</div><div class="l">失败</div></div>
  <div class="card"><div class="n">{npass + nfail}</div><div class="l">断言总数</div></div>
</div>
<table><thead><tr><th>#</th><th>状态</th><th>用例 / 断言</th></tr></thead>
<tbody>{''.join(trs)}</tbody></table>
</div></body></html>"""

    with open(os.path.join(run, "report.html"), "w", encoding="utf-8") as f:
        f.write(out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
