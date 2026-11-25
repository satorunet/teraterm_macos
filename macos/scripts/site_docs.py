#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Mac 版マニュアル (Resources/help-mac/{ja,en}/html) を公式サイト (teraterm-mac.github.io) の /docs/{ja,en}/ に書き出す。

  python3 scripts/site_docs.py <サイトのフォルダ>

- ページはすべて UTF-8 にそろえる (元は Shift_JIS / iso-8859-1 が混ざる)
- 画像はアプリと同じく、手元に無いものは本家の公開マニュアル (teratermproject.github.io/manual/5/<言語>/) から読む
- 各ページの上にパンくずと言語の切り替え、下に「前へ / 次へ」(modern-toc.json の順) を付ける
- 目次 (index.html) は modern-toc.json から作る。アプリ用の modern.html も同じ目次にする
"""
import html, json, os, re, shutil, sys

HERE = os.path.dirname(os.path.abspath(__file__))
HELP = os.path.join(HERE, '..', 'Resources', 'help-mac')
UPSTREAM = 'https://teratermproject.github.io/manual/5/{lang}/'

L = {
    'ja': dict(site='Tera Term Mac', docs='ドキュメント', toc='目次', prev='前へ', next='次へ', other='English',
               title='Tera Term Mac ドキュメント', search='目次を絞り込む',
               lead='Tera Term Mac の使い方です。はじめての方は「かんたんマニュアル」から読んでください。アプリの [ヘルプ] メニューからも同じものが読めます。'),
    'en': dict(site='Tera Term Mac', docs='Documentation', toc='Contents', prev='Previous', next='Next', other='日本語',
               title='Tera Term Mac documentation', search='Filter the contents',
               lead='How to use Tera Term Mac. If you are new, start with the quick guide. The same pages are in the app\'s [Help] menu.'),
}

CHARSET = re.compile(r'(<meta[^>]+charset\s*=\s*["\']?)[A-Za-z0-9_\-]+', re.I)


def read_text(p):
    b = open(p, 'rb').read()
    try:
        return b.decode('utf-8')
    except UnicodeDecodeError:
        pass
    head = b[:2000].decode('ascii', 'ignore').lower()
    if 'shift_jis' in head or 'shift-jis' in head:
        return b.decode('cp932', 'replace')
    return b.decode('cp1252', 'replace')


def build(site):
    for lang in ('ja', 'en'):
        t = L[lang]
        src = os.path.join(HELP, lang, 'html')
        dst = os.path.join(site, 'docs', lang)
        if os.path.isdir(dst):
            shutil.rmtree(dst)
        shutil.copytree(src, dst)
        toc = json.load(open(os.path.join(HELP, lang, 'modern-toc.json'), encoding='utf-8'))

        # 読む順 (前へ / 次へ)
        order, seen, title_of = [], set(), {}
        for g in toc:
            for it in g['items']:
                p = it['p'].split('#')[0]
                title_of.setdefault(p, it['t'])
                if p not in seen:
                    seen.add(p)
                    order.append(p)

        # 目次
        groups = []
        for i, g in enumerate(toc, 1):
            lis = ''.join(f'<li><a href="{html.escape(it["p"])}">{html.escape(it["t"])}</a></li>' for it in g['items'])
            groups.append(f'<section class="tg"><h2><span>{i}.</span> {html.escape(g["t"])}</h2><ul>{lis}</ul></section>')
        index = f'''<!DOCTYPE html>
<html lang="{lang}">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>{t['title']}</title>
<link rel="icon" href="../../favicon.png">
<link rel="stylesheet" href="../docs.css">
</head>
<body class="ttw-index">
<nav class="ttw-bar"><a href="../../{'' if lang == 'ja' else 'en/'}">{t['site']}</a> › <b>{t['docs']}</b><a class="ttw-lang" href="../{'en' if lang == 'ja' else 'ja'}/">{t['other']}</a></nav>
<main class="ttw-main">
<h1>{t['title']}</h1>
<p class="ttw-lead">{t['lead']}</p>
<input class="ttw-filter" type="search" placeholder="{t['search']}" oninput="var q=this.value.toLowerCase();document.querySelectorAll('.tg li').forEach(function(li){{li.style.display=li.textContent.toLowerCase().indexOf(q)<0?'none':''}});document.querySelectorAll('.tg').forEach(function(s){{s.style.display=[].some.call(s.querySelectorAll('li'),function(li){{return li.style.display!=='none'}})?'':'none'}})">
<div class="ttw-toc">{''.join(groups)}</div>
</main>
</body>
</html>
'''
        for name in ('index.html', 'modern.html'):
            open(os.path.join(dst, name), 'w', encoding='utf-8').write(index)

        # 各ページ
        for root, _, files in os.walk(dst):
            for f in files:
                if not f.endswith('.html'):
                    continue
                p = os.path.join(root, f)
                rel = os.path.relpath(p, dst).replace(os.sep, '/')
                if rel in ('index.html', 'modern.html'):
                    continue
                s = read_text(p)
                s = CHARSET.sub(lambda m: m.group(1) + 'utf-8', s)
                up = '../' * rel.count('/')

                # 手元に無い画像は本家の公開マニュアルから
                def img(m):
                    a, q, v = m.group(1), m.group(2), m.group(3)
                    if re.match(r'^[a-z]+:', v) or v.startswith('/'):
                        return m.group(0)
                    target = os.path.normpath(os.path.join(os.path.dirname(rel), v)).replace(os.sep, '/')
                    if os.path.exists(os.path.join(dst, target)):
                        return m.group(0)
                    return f'{a}{q}{UPSTREAM.format(lang=lang)}{target}{q}'
                s = re.sub(r'(<img\b[^>]*?\bsrc\s*=\s*)(["\']?)([^"\'\s>]+)\2', img, s, flags=re.I)

                if 'docs.css' not in s:
                    s = re.sub(r'</head>', f'<meta name="viewport" content="width=device-width,initial-scale=1">\n<link rel="stylesheet" href="{up}../docs.css">\n</head>', s, count=1, flags=re.I)
                other = 'en' if lang == 'ja' else 'ja'
                other_href = f'{up}../{other}/{rel}' if os.path.exists(os.path.join(HELP, other, 'html', rel)) else f'{up}../{other}/'
                crumb = f'<a href="{up}../../{"" if lang == "ja" else "en/"}">{t["site"]}</a> › <a href="{up}index.html">{t["docs"]}</a>'
                if rel in title_of:
                    crumb += f' › <span>{html.escape(title_of[rel])}</span>'
                bar = f'<nav class="ttw-bar">{crumb}<a class="ttw-lang" href="{other_href}">{t["other"]}</a></nav>\n<main class="ttw-main">\n'
                s = re.sub(r'(<body\b[^>]*>)', lambda m: m.group(1) + '\n' + bar, s, count=1, flags=re.I)
                pager = ''
                if rel in order:
                    k = order.index(rel)
                    pv = f'<a class="ttw-prev" href="{up}{order[k-1]}">‹ {html.escape(title_of[order[k-1]])}</a>' if k > 0 else '<span></span>'
                    nx = f'<a class="ttw-next" href="{up}{order[k+1]}">{html.escape(title_of[order[k+1]])} ›</a>' if k + 1 < len(order) else '<span></span>'
                    pager = f'<nav class="ttw-pager">{pv}<a href="{up}index.html">{t["toc"]}</a>{nx}</nav>\n'
                s = re.sub(r'</body>', '</main>\n' + pager + '</body>', s, count=1, flags=re.I)
                open(p, 'w', encoding='utf-8').write(s)
        for junk in ('teraterm.hhp',):
            jp = os.path.join(dst, junk)
            if os.path.exists(jp):
                os.remove(jp)
    print('docs:', os.path.join(site, 'docs'))


if __name__ == '__main__':
    build(os.path.abspath(sys.argv[1]))
