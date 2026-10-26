"""生成 T3.2 评测用的合成试卷（中文 PDF）。

为什么要合成：切题规则的可用率不能只在一份真卷上量——真实卷子排版千差万别，
而"单栏 / 双栏 / 括号小题 / 【例】+ 跨页长题"这四类恰好是规则最容易翻车的地方。
本脚本用 Edge 的无头打印（本机已装）把 HTML 打成 PDF，产出可复现的评测语料。

用法（在 main/ 下）：
    python tool/make_test_papers.py
产物：demo_assets/papers/*.pdf（不进包，仅供手工/真机评测）
"""
import io
import os
import subprocess
import sys
import tempfile

EDGE_CANDIDATES = [
    r'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe',
    r'C:\Program Files\Microsoft\Edge\Application\msedge.exe',
]

CSS_BASE = """
@page { size: A4; margin: 18mm 16mm; }
body { font-family: "Microsoft YaHei", "SimSun", serif; font-size: 10.5pt; line-height: 1.75; color: #000; }
h1 { font-size: 15pt; text-align: center; margin: 0 0 4pt; }
.sub { text-align: center; font-size: 9pt; margin-bottom: 12pt; }
p { margin: 0 0 6pt; text-indent: 0; }
.opts { margin: 2pt 0 8pt 14pt; }
.two { column-count: 2; column-gap: 10mm; }
.long { height: 150mm; }
"""


def paper_single_column():
    """单栏，全卷只有 1.–10.（没有大题标题）→ 测"全同级"路径。"""
    items = []
    for i in range(1, 11):
        items.append(
            f'<p>{i}. 设函数 f(x)=x^{i}+{i}x，求 f′(x) 的零点个数，并说明理由。</p>'
            f'<p class="opts">A. 0 个　B. 1 个　C. 2 个　D. 3 个</p>'
        )
    return (
        '<h1>2025–2026 学年第一学期《数学分析》单元测验</h1>'
        '<div class="sub">一、计算与证明（每题 10 分，共 100 分）</div>'
        + ''.join(items)
    )


def paper_double_column():
    """双栏：一、选择题 + 1.–8.，用 CSS 两栏排版 → 测分栏检测。"""
    items = []
    for i in range(1, 9):
        items.append(
            f'<p>{i}. 下列说法正确的是（　）</p>'
            f'<p class="opts">A. 收敛数列必有界 B. 有界数列必收敛<br>'
            f'C. 单调数列必收敛 D. 以上都不对</p>'
        )
    return (
        '<h1>高等数学（上）期中试卷</h1>'
        '<div class="sub">考试时间 120 分钟　满分 100 分</div>'
        '<div class="two"><p><b>一、选择题（每小题 5 分，共 40 分）</b></p>'
        + ''.join(items)
        + '</div>'
    )


def paper_paren_style():
    """大题 1./2. + 小题（1）（2）→ 测"两级并存"层级判定。"""
    body = []
    for big in range(1, 5):
        body.append(f'<p><b>{big}. （15 分）设函数 f(x)=ln(1+x^{big})，完成下列各问：</b></p>')
        for small in range(1, 4):
            body.append(
                f'<p>（{small}）求 f(x) 在 x=0 处的 {small} 阶导数，并写出求解过程；</p>'
            )
        body.append('<p>（4）判断 f(x) 在定义域内是否一致连续，并说明理由。</p>')
    return (
        '<h1>数学分析（下）期末考试</h1>'
        '<div class="sub">闭卷　可用计算器</div>' + ''.join(body)
    )


def paper_example_cross_page():
    """【例 7】+ 一题占满一页多 → 测跨页与例号识别。"""
    body = []
    for i in range(1, 5):
        body.append(f'<p>【例 {i}】求下列极限，并说明每一步的依据：</p>')
        for j in range(1, 9):
            body.append(
                f'<p>（{j}）lim<sub>x→{j}</sub> (x+{i})^{j} / (x−{i})，其中 x 为实数。</p>'
            )
    body.append('<p>【例 5】证明：若函数列一致收敛，则极限函数连续。</p>')
    body.append('<div class="long"></div>')
    body.append('<p>【例 6】设 f 在 [0,1] 上连续，证明存在 ξ 使 f(ξ)=0。</p>')
    return (
        '<h1>数学分析习题选讲</h1>'
        '<div class="sub">第五章　极限与连续</div>' + ''.join(body)
    )


PAPERS = {
    'eval-single-column.pdf': paper_single_column(),
    'eval-double-column.pdf': paper_double_column(),
    'eval-paren-sub.pdf': paper_paren_style(),
    'eval-example-crosspage.pdf': paper_example_cross_page(),
}


def find_edge():
    for path in EDGE_CANDIDATES:
        if os.path.exists(path):
            return path
    return None


def main():
    edge = find_edge()
    if edge is None:
        print('找不到 Edge，无法生成 PDF', file=sys.stderr)
        return 1
    out_dir = os.path.join('demo_assets', 'papers')
    os.makedirs(out_dir, exist_ok=True)

    for name, body in PAPERS.items():
        html = (
            '<!doctype html><html><head><meta charset="utf-8">'
            f'<style>{CSS_BASE}</style></head><body>{body}</body></html>'
        )
        with tempfile.TemporaryDirectory() as tmp:
            html_path = os.path.join(tmp, 'paper.html')
            io.open(html_path, 'w', encoding='utf-8', newline='\n').write(html)
            pdf_path = os.path.abspath(os.path.join(out_dir, name))
            cmd = [
                edge,
                '--headless=new',
                '--disable-gpu',
                '--no-sandbox',
                f'--user-data-dir={tmp}',
                f'--print-to-pdf={pdf_path}',
                '--no-pdf-header-footer',
                'file:///' + html_path.replace('\\', '/'),
            ]
            result = subprocess.run(cmd, capture_output=True, text=True)
            size = os.path.getsize(pdf_path) if os.path.exists(pdf_path) else 0
            print(f'{name}: {size} bytes (exit {result.returncode})')
            if size == 0 and result.stderr:
                print(result.stderr[:400], file=sys.stderr)
    return 0


if __name__ == '__main__':
    sys.exit(main())
