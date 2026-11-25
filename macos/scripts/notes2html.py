#!/usr/bin/env python3
# リリースノート (GitHub Releases と同じ Markdown) を、更新の画面 (Sparkle) に出す HTML にする
#   python3 scripts/notes2html.py notes.md > notes.html
# 使えるのは、段落・**見出し**・「- 」の箇条書き・`コード`・**太字** だけ (リリースノートで使うもの)
import html
import re
import sys

STYLE = """<style>
body { font: 13px -apple-system, "Hiragino Sans", sans-serif; line-height: 1.5; margin: 8px 12px; color: #222; }
@media (prefers-color-scheme: dark) { body { color: #ddd; background: transparent; } code { background: #333; } }
h3 { font-size: 13px; margin: 12px 0 4px; }
ul { margin: 4px 0; padding-left: 20px; }
li { margin: 2px 0; }
p { margin: 6px 0; }
code { font: 12px Menlo, monospace; background: #eee; padding: 0 3px; border-radius: 3px; }
.foot { color: #888; font-size: 11px; }
</style>"""


def inline(s: str) -> str:
    s = html.escape(s)
    s = re.sub(r"`([^`]+)`", r"<code>\1</code>", s)
    s = re.sub(r"\*\*([^*]+)\*\*", r"<b>\1</b>", s)
    s = re.sub(r"\[([^\]]+)\]\((https?://[^)]+)\)", r'<a href="\2">\1</a>', s)
    return s


def convert(md: str) -> str:
    out, in_list = [STYLE], False
    for line in md.splitlines():
        line = line.rstrip()
        if line.startswith("🤖"):          # Claude Code の行は更新の画面には出さない
            continue
        if line.startswith("- "):
            if not in_list:
                out.append("<ul>"); in_list = True
            out.append(f"<li>{inline(line[2:])}</li>")
            continue
        if in_list:
            out.append("</ul>"); in_list = False
        if not line:
            continue
        m = re.fullmatch(r"\*\*(.+)\*\*", line)
        if m:
            out.append(f"<h3>{inline(m.group(1))}</h3>")
        elif line.startswith("対応:"):
            out.append(f'<p class="foot">{inline(line)}</p>')
        else:
            out.append(f"<p>{inline(line)}</p>")
    if in_list:
        out.append("</ul>")
    return "\n".join(out)


if __name__ == "__main__":
    sys.stdout.write(convert(open(sys.argv[1], encoding="utf-8").read()))
