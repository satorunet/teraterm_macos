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
               title='Tera Term Mac ドキュメント', search='目次を絞り込む', ref='マクロ リファレンス', refsearch='絞り込む', refsyn='文法', refdoc='資料', refcmd='コマンド (ABC 順)', reflink='文法・資料・コマンドの一覧',
               reflead='TTL マクロの文法、資料、コマンドの一覧です。はじめての方は、目次の「マクロ」の章から読んでください。', refcount='{n} 個のコマンド',
               lead='Tera Term Mac の使い方です。はじめての方は「かんたんマニュアル」から読んでください。アプリの [ヘルプ] メニューからも同じものが読めます。'),
    'en': dict(site='Tera Term Mac', docs='Documentation', toc='Contents', prev='Previous', next='Next', other='日本語',
               title='Tera Term Mac documentation', search='Filter the contents', ref='Macro reference', refsearch='Filter', refsyn='Language', refdoc='Appendixes', refcmd='Commands (A–Z)', reflink='Language, appendixes and all commands',
               reflead='The TTL language, appendixes, and every macro command. If you are new to macros, start with the "Macros" chapter of the contents.', refcount='{n} commands',
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

        # 目次。マクロのコマンド (数百項目) は別のリファレンスのページにまとめ、目次には 1 行だけ出す
        # マクロの章は概要だけを目次に出し、文法・資料・コマンド (数百項目) は別のリファレンスのページにまとめる
        CMD_GROUPS = ('マクロのコマンド', 'Macro commands')
        MACRO_GROUPS = ('マクロ', 'Macros')
        OVERVIEW = ('macro/index.html', 'macro/howtorun.html', 'macro/howtoassoc.html', 'macro/syntax/index.html')
        groups, ref_items, syn_items, doc_items = [], [], [], []
        n = 0
        for g in toc:
            if g['t'] in CMD_GROUPS:
                ref_items = g['items']
                continue
            n += 1
            items = g['items']
            extra = ''
            if g['t'] in MACRO_GROUPS:
                for it in items:
                    if it['p'] in OVERVIEW:
                        continue
                    (syn_items if it['p'].startswith('macro/syntax/') else doc_items).append(it)
                items = [it for it in items if it['p'] in OVERVIEW]
                extra = f'<li class="tref"><a href="macro-reference.html"><b>{t["ref"]} ›</b></a><br><small>{t["reflink"]}</small></li>'
            lis = ''.join(f'<li><a href="{html.escape(it["p"])}">{html.escape(it["t"])}</a></li>' for it in items) + extra
            groups.append(f'<section class="tg"><h2><span>{n}.</span> {html.escape(g["t"])}</h2><ul>{lis}</ul></section>')
        all_ref = ref_items + syn_items + doc_items
        if ref_items:
            by = {}
            for it in sorted(ref_items, key=lambda it: it['t'].lower()):
                by.setdefault(it['t'][:1].upper(), []).append(it)
            letters = ''.join(f'<a href="#k-{k}">{k}</a>' for k in by)
            def plain(title, items, hid):
                return f'<section class="rk rk-wide" id="{hid}"><h2>{title}</h2><ul>' + ''.join(f'<li><a href="{html.escape(it["p"])}">{html.escape(it["t"])}</a></li>' for it in items) + '</ul></section>'
            blocks = plain(t['refsyn'], syn_items, 'syntax') + plain(t['refdoc'], doc_items, 'appendix') + f'<h2 class="rk-head" id="commands">{t["refcmd"]}</h2><nav class="rk-letters">{letters}</nav>' + ''.join(f'<section class="rk" id="k-{k}"><h2>{k}</h2><ul>' + ''.join(f'<li><a href="{html.escape(it["p"])}"><code>{html.escape(it["t"])}</code></a></li>' for it in v) + '</ul></section>' for k, v in by.items())
            letters = f'<a href="#syntax">{t["refsyn"]}</a><a href="#appendix">{t["refdoc"]}</a><a href="#commands">{t["refcmd"]}</a>'
            ref = f'''<!DOCTYPE html>
<html lang="{lang}">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>{t['ref']} - Tera Term Mac</title>
<link rel="icon" href="../../favicon.png">
<link rel="stylesheet" href="../docs.css">
</head>
<body class="ttw-index">
<nav class="ttw-bar"><a href="../../{'' if lang == 'ja' else 'en/'}">{t['site']}</a> › <a href="index.html">{t['docs']}</a> › <b>{t['ref']}</b><a class="ttw-lang" href="../{'en' if lang == 'ja' else 'ja'}/macro-reference.html">{t['other']}</a></nav>
<main class="ttw-main">
<h1>{t['ref']}</h1>
<p class="ttw-lead">{t['reflead']}</p>
<input class="ttw-filter" type="search" placeholder="{t['refsearch']}" oninput="var q=this.value.toLowerCase();document.querySelectorAll('.rk li').forEach(function(li){{li.style.display=li.textContent.toLowerCase().indexOf(q)<0?'none':''}});document.querySelectorAll('.rk').forEach(function(s){{s.style.display=[].some.call(s.querySelectorAll('li'),function(li){{return li.style.display!=='none'}})?'':'none'}})">
<nav class="rk-letters">{letters}</nav>
<div class="rk-all">{blocks}</div>
</main>
</body>
</html>
'''
            open(os.path.join(dst, 'macro-reference.html'), 'w', encoding='utf-8').write(ref)
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
                if rel in ('index.html', 'modern.html', 'macro-reference.html'):
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
                if all_ref and any(it['p'].split('#')[0] == rel for it in all_ref):
                    crumb += f' › <a href="{up}macro-reference.html">{t["ref"]}</a>'
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


def app_reference():
    """アプリのヘルプ用の「マクロ リファレンス」(help-mac/<言語>/html/macro-reference.html) を modern-toc.json から作る。
    アプリの目次 (HelpModernStyle.toc) は、マクロの章を概要 + このページだけにし、コマンドの章を出さない"""
    OVERVIEW = ('macro/index.html', 'macro/howtorun.html', 'macro/howtoassoc.html', 'macro/syntax/index.html')
    for lang in ('ja', 'en'):
        t = L[lang]
        toc = json.load(open(os.path.join(HELP, lang, 'modern-toc.json'), encoding='utf-8'))
        cmds = next(g['items'] for g in toc if g['t'] in ('マクロのコマンド', 'Macro commands'))
        macro = next(g['items'] for g in toc if g['t'] in ('マクロ', 'Macros'))
        syn = [it for it in macro if it['p'] not in OVERVIEW and it['p'].startswith('macro/syntax/')]
        doc = [it for it in macro if it['p'] not in OVERVIEW and not it['p'].startswith('macro/syntax/')]
        by = {}
        for it in sorted(cmds, key=lambda it: it['t'].lower()):
            by.setdefault(it['t'][:1].upper(), []).append(it)
        li = lambda items, code=False: ''.join(f'<li><a href="{html.escape(it["p"])}">{"<code>" if code else ""}{html.escape(it["t"])}{"</code>" if code else ""}</a></li>' for it in items)
        letters = ' '.join(f'<a href="#k-{k}">{k}</a>' for k in by)
        body = (f'<h2 id="syntax">{t["refsyn"]}</h2><ul class="mr">{li(syn)}</ul>'
                f'<h2 id="appendix">{t["refdoc"]}</h2><ul class="mr">{li(doc)}</ul>'
                f'<h2 id="commands">{t["refcmd"]}</h2><p class="mr-letters">{letters}</p>'
                + ''.join(f'<h3 id="k-{k}">{k}</h3><ul class="mr mr-cmd">{li(v, True)}</ul>' for k, v in by.items()))
        page = f'''<!DOCTYPE html>
<html lang="{lang}">
<head>
<meta charset="utf-8">
<title>{t['ref']}</title>
<link rel="stylesheet" href="style.css" type="text/css">
<style>
ul.mr{{list-style:none;padding:0;display:grid;grid-template-columns:repeat(auto-fill,minmax(210px,1fr));gap:2px 16px}}
ul.mr-cmd{{grid-template-columns:repeat(auto-fill,minmax(170px,1fr))}}
.mr-letters a{{display:inline-block;min-width:1.6em;text-align:center}}
input.mr-filter{{width:100%;font:inherit;padding:6px 10px;margin:4px 0 8px;box-sizing:border-box}}
</style>
</head>
<body>
<h1>{t['ref']}</h1>
<p>{t['reflead']}</p>
<input class="mr-filter" type="search" placeholder="{t['refsearch']}" oninput="var q=this.value.toLowerCase();document.querySelectorAll('ul.mr li').forEach(function(li){{li.style.display=li.textContent.toLowerCase().indexOf(q)<0?'none':''}})">
{body}
</body>
</html>
'''
        open(os.path.join(HELP, lang, 'html', 'macro-reference.html'), 'w', encoding='utf-8').write(page)
    print('app reference: help-mac/{ja,en}/html/macro-reference.html')


if __name__ == '__main__':
    if sys.argv[1:] == ['--app']:
        app_reference()
    else:
        app_reference()
        build(os.path.abspath(sys.argv[1]))
