import Foundation
import TeraCore

/// Mac 版マニュアルの見た目 (製本)。ページの HTML はそのままで、表示するときに
/// 新しい見た目 (システムのフォント・広めの行間・ダークモード) と、章番号付きの目次・検索・前へ/次へ・いまの章をかぶせる。
/// 従来のマニュアル (本家のヘルプ) には何もかぶせない
enum HelpModernStyle {

    /// モダン表示のトップページ (やりたいこと別の目次。無ければ従来の目次 index.html)
    static func homePage(helpRoot: String) -> String {
        FileManager.default.fileExists(atPath: (helpRoot as NSString).appendingPathComponent("html/modern.html")) ? "html/modern.html" : "html/index.html"
    }

    /// 左の目次 → [{t: 見出し, items: [{t, u}]}]。u は file URL。
    /// やりたいこと別の目次 (<言語>/modern-toc.json: [{t, items: [{t, p: html/ からのパス}]}]) があればそれ、
    /// 無ければ従来の目次 (html/index.html の「div.topic」とその下のリンク)
    static func toc(helpRoot: String) -> [[String: Any]] {
        let html = URL(fileURLWithPath: (helpRoot as NSString).appendingPathComponent("html"), isDirectory: true)
        if let d = FileManager.default.contents(atPath: (helpRoot as NSString).appendingPathComponent("modern-toc.json")),
           let groups = try? JSONSerialization.jsonObject(with: d) as? [[String: Any]] {
            // マクロの章は概要だけにして「マクロ リファレンス」(文法・資料・コマンド。scripts/site_docs.py --app で作る) へ。
            // コマンドの章 (数百項目) は目次に出さない
            let hasRef = FileManager.default.fileExists(atPath: html.appendingPathComponent("macro-reference.html").path)
            let overview: Set<String> = ["macro/index.html", "macro/howtorun.html", "macro/howtoassoc.html", "macro/syntax/index.html"]
            return groups.compactMap { g in
                guard let t = g["t"] as? String, var items = g["items"] as? [[String: String]] else { return nil }
                if hasRef {
                    if ["マクロのコマンド", "Macro commands"].contains(t) { return nil }
                    if ["マクロ", "Macros"].contains(t) {
                        items = items.filter { overview.contains($0["p"] ?? "") }
                        items.append(["t": (helpRoot as NSString).lastPathComponent != "en" ? "マクロ リファレンス (文法・資料・コマンド)" : "Macro reference (language, appendixes, commands)",
                                      "p": "macro-reference.html"])
                    }
                }
                let list: [[String: String]] = items.compactMap { it in
                    guard let title = it["t"], let p = it["p"], let u = URL(string: p, relativeTo: html)?.absoluteURL else { return nil }
                    return ["t": title, "u": u.absoluteString]
                }
                return list.isEmpty ? nil : ["t": t, "items": list]
            }
        }
        let path = (helpRoot as NSString).appendingPathComponent("html/index.html")
        guard let data = FileManager.default.contents(atPath: path) else { return [] }
        let text = decode(data)
        let base = URL(fileURLWithPath: path).deletingLastPathComponent()
        var out: [[String: Any]] = []
        // <div class="topic" ...>見出し</div> ... 次の topic まで
        let parts = text.components(separatedBy: "<div class=\"topic\"")
        for part in parts.dropFirst() {
            guard let gt = part.firstIndex(of: ">"), let end = part.range(of: "</div>") else { continue }
            let title = strip(String(part[part.index(after: gt)..<end.lowerBound]))
            var items: [[String: String]] = []
            let body = String(part[end.upperBound...])
            let re = try! NSRegularExpression(pattern: "<a\\s+href=\"([^\"]+)\"[^>]*>(.*?)</a>", options: [.caseInsensitive, .dotMatchesLineSeparators])
            for m in re.matches(in: body, range: NSRange(body.startIndex..., in: body)) {
                guard let hr = Range(m.range(at: 1), in: body), let tr = Range(m.range(at: 2), in: body) else { continue }
                let href = String(body[hr])
                if href.hasPrefix("http") || href.hasPrefix("mailto") { continue }
                guard let u = URL(string: href, relativeTo: base)?.absoluteURL else { continue }
                items.append(["t": strip(String(body[tr])), "u": u.absoluteString])
            }
            if !title.isEmpty && !items.isEmpty { out.append(["t": title, "items": items]) }
        }
        return out
    }

    /// ページの文字コード (meta charset。無ければ UTF-8 → Shift_JIS)
    static func decode(_ d: Data) -> String {
        let head = String(decoding: d.prefix(2048), as: UTF8.self).lowercased()
        if head.contains("shift_jis") || head.contains("x-sjis") {
            return String(data: d, encoding: .shiftJIS) ?? String(decoding: d, as: UTF8.self)
        }
        if head.contains("iso-8859-1") { return String(data: d, encoding: .isoLatin1) ?? "" }
        return String(data: d, encoding: .utf8) ?? String(data: d, encoding: .shiftJIS) ?? ""
    }
    private static func strip(_ s: String) -> String {
        var r = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        for (a, b) in [("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&nbsp;", " ")] { r = r.replacingOccurrences(of: a, with: b) }
        return r.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
    }

    static let css = """
    :root { color-scheme: light dark;
      --bg: #ffffff; --fg: #1d1d1f; --muted: #6e6e73; --line: #e5e5ea; --accent: #0a66d8;
      --code-bg: #f5f5f7; --side-bg: #f7f7f9; --hl: #fff6cc; --note-bg: #eef5ff; --note-line: #b8d4fb; --warn: #c62828;
      --hover: rgba(10,102,216,.10); --cur: rgba(10,102,216,.16); --zebra: rgba(0,0,0,.025); }
    @media (prefers-color-scheme: dark) { :root {
      --bg: #1e1e20; --fg: #e8e8ea; --muted: #a1a1a6; --line: #38383c; --accent: #5aa2ff;
      --code-bg: #2a2a2e; --side-bg: #252528; --hl: #4a4220; --note-bg: #1f2d44; --note-line: #36537d; --warn: #ff6b6b;
      --hover: rgba(90,162,255,.14); --cur: rgba(90,162,255,.22); --zebra: rgba(255,255,255,.03); } }
    html { background: var(--bg) !important; }
    body { margin: 0 !important; background: var(--bg) !important; color: var(--fg) !important;
      font: 14px/1.7 -apple-system, "Hiragino Sans", "Hiragino Kaku Gothic ProN", "Helvetica Neue", sans-serif !important; }
    #ttm-main { max-width: 860px; margin: 0 auto; padding: 28px 40px 80px; }
    body.ttm-has-side #ttm-main { margin-left: 280px; }
    h1 { font-size: 26px !important; font-weight: 700; letter-spacing: -0.01em; margin: 0 0 18px; padding-bottom: 10px; border-bottom: 1px solid var(--line); }
    h1.center { text-align: left !important; }
    h2 { font-size: 20px !important; font-weight: 650; margin: 34px 0 10px; }
    h3 { font-size: 16px !important; font-weight: 650; margin: 26px 0 8px; }
    h4 { font-size: 14px !important; font-weight: 650; }
    p, li, dd { color: var(--fg); }
    a { color: var(--accent); text-decoration: none; } a:hover { text-decoration: underline; }
    ul, ol { margin: 6px 0 12px !important; padding-left: 1.4em; } li { margin: 3px 0; }
    pre, code, .code, kbd, tt { font-family: "SF Mono", Menlo, Monaco, monospace !important; font-size: 12.5px; }
    pre { background: var(--code-bg) !important; color: var(--fg) !important; border: 1px solid var(--line); border-radius: 8px;
      padding: 12px 14px !important; overflow-x: auto; line-height: 1.5; }
    pre.macro-example { background: var(--hl) !important; }
    .code, .variable { color: var(--accent) !important; }
    kbd { border: 1px solid var(--line); border-bottom-width: 2px; border-radius: 4px; padding: 0 5px; background: var(--code-bg); }
    table { border-collapse: collapse; margin: 10px 0 16px; font-size: 13.5px; }
    th, td { border: 1px solid var(--line) !important; padding: 6px 10px; vertical-align: top; }
    th { background: var(--code-bg); font-weight: 600; }
    tr:nth-child(even) td { background: var(--zebra); }
    dt { border: 0 !important; padding: 10px 0 2px !important; font-weight: 650; }
    dd { margin: 0 0 8px 1.2em; }
    .notice { color: var(--fg) !important; background: var(--note-bg); border: 1px solid var(--note-line); border-left-width: 4px;
      border-radius: 6px; padding: 8px 12px; }
    span.notice, font.notice { display: inline; padding: 0 4px; }
    .warning { color: var(--warn) !important; }
    div.topic { font-size: 18px !important; font-weight: 650 !important; margin: 30px 0 8px !important; }
    font.new { color: var(--accent) !important; }
    hr { border: 0; border-top: 1px solid var(--line); margin: 24px 0; }
    img { max-width: 100%; height: auto; border-radius: 6px; }
    /* 目次ページ: 項目をカードに */
    body.ttm-index div.topic + ul { display: grid; grid-template-columns: repeat(auto-fill, minmax(230px, 1fr)); gap: 8px;
      list-style: none; padding: 0; }
    body.ttm-index div.topic + ul > li { margin: 0; background: var(--code-bg); border: 1px solid var(--line); border-radius: 8px; padding: 8px 12px; }
    /* 左の目次 */
    #ttm-side { position: fixed; top: 0; left: 0; bottom: 0; width: 260px; overflow-y: auto; background: var(--side-bg);
      border-right: 1px solid var(--line); padding: 14px 10px 40px; box-sizing: border-box; font-size: 13px; }
    #ttm-side input { width: 100%; box-sizing: border-box; padding: 6px 9px; border-radius: 7px; border: 1px solid var(--line);
      background: var(--bg); color: var(--fg); font: inherit; margin-bottom: 10px; outline: none; }
    #ttm-side input:focus { border-color: var(--accent); }
    #ttm-side details { margin: 2px 0; } #ttm-side summary { cursor: pointer; font-weight: 600; padding: 4px 6px; border-radius: 6px; list-style: none; }
    #ttm-side summary::-webkit-details-marker { display: none; }
    #ttm-side summary::before { content: "›"; display: inline-block; width: 12px; color: var(--muted); transition: transform .15s; }
    #ttm-side details[open] > summary::before { transform: rotate(90deg); }
    #ttm-side summary:hover, #ttm-side a:hover { background: var(--hover); text-decoration: none; }
    #ttm-side a { display: block; color: var(--fg); padding: 3px 6px 3px 20px; border-radius: 6px; line-height: 1.4; }
    #ttm-side a.cur { background: var(--cur); color: var(--accent); font-weight: 600; }
    #ttm-side .home { display: block; font-weight: 700; padding: 4px 6px; margin-bottom: 6px; color: var(--fg); }
    .ttm-crumb { font-size: 12.5px; color: var(--muted); margin: -8px 0 14px; }
    .ttm-crumb a { color: var(--muted); }
    .ttm-pager { display: flex; justify-content: space-between; gap: 12px; margin-top: 48px; padding-top: 16px; border-top: 1px solid var(--line); }
    .ttm-pager a { display: flex; flex-direction: column; max-width: 48%; padding: 10px 14px; border: 1px solid var(--line); border-radius: 8px; }
    .ttm-pager a:hover { background: var(--hover); text-decoration: none; }
    .ttm-pager a.next { margin-left: auto; text-align: right; }
    .ttm-pager .lbl { font-size: 11.5px; color: var(--muted); }
    @media (max-width: 760px) { #ttm-side { display: none; } body.ttm-has-side #ttm-main { margin-left: auto; } }
    """

    /// toc: 目次の JSON、index: 目次ページの URL、search: 検索欄の文字
    static func js(tocJSON: String, indexURL: String, homeTitle: String, searchPlaceholder: String,
                   prev: String = "\"←\"", next: String = "\"→\"") -> String {
        """
        (function () {
          if (window.__ttmModern) return; window.__ttmModern = true;
          var TOC = \(tocJSON), INDEX = \(indexURL), HOME = \(homeTitle), PH = \(searchPlaceholder), PREV = \(prev), NEXT = \(next);
          var main = document.createElement('div'); main.id = 'ttm-main';
          while (document.body.firstChild) main.appendChild(document.body.firstChild);
          document.body.appendChild(main);
          var here = location.href.split('#')[0];
          if (here === INDEX || /[/]html[/](index|modern)[.]html$/.test(here)) document.body.classList.add('ttm-index');
          var reveal = function () { document.documentElement.classList.add('ttm-ready'); };
          if (!TOC.length) { reveal(); return; }
          document.body.classList.add('ttm-has-side');
          var side = document.createElement('nav'); side.id = 'ttm-side';
          var home = document.createElement('a'); home.className = 'home'; home.href = INDEX; home.textContent = HOME; side.appendChild(home);
          var q = document.createElement('input'); q.type = 'search'; q.placeholder = PH; side.appendChild(q);
          var groups = [], flat = [], curIdx = -1;
          TOC.forEach(function (sec, i) {
            var d = document.createElement('details'); var s = document.createElement('summary');
            s.textContent = (i + 1) + '. ' + sec.t; d.appendChild(s);
            var links = [];
            sec.items.forEach(function (it, j) {
              var num = (i + 1) + '.' + (j + 1);
              var a = document.createElement('a'); a.href = it.u; a.textContent = num + '  ' + it.t;
              if (curIdx < 0 && it.u.split('#')[0] === here) { a.className = 'cur'; d.open = true; curIdx = flat.length; }
              d.appendChild(a); links.push(a);
              flat.push({ u: it.u, t: it.t, num: num, chap: (i + 1) + '. ' + sec.t, chapU: sec.items[0].u });
            });
            side.appendChild(d); groups.push({ d: d, links: links, open: d.open });
          });
          // いまの章 (上) と 前へ / 次へ (下)
          if (curIdx >= 0) {
            var c = flat[curIdx];
            var crumb = document.createElement('div'); crumb.className = 'ttm-crumb';
            var ch = document.createElement('a'); ch.href = c.chapU; ch.textContent = c.chap;
            crumb.appendChild(ch); crumb.appendChild(document.createTextNode('  ›  ' + c.num + '  ' + c.t));
            main.insertBefore(crumb, main.firstChild);
            var pager = document.createElement('div'); pager.className = 'ttm-pager';
            function link(it, cls, label) {
              var a = document.createElement('a'); a.className = cls; a.href = it.u;
              var l = document.createElement('span'); l.className = 'lbl'; l.textContent = label;
              var t = document.createElement('span'); t.textContent = it.num + '  ' + it.t;
              a.appendChild(l); a.appendChild(t); return a;
            }
            pager.appendChild(curIdx > 0 ? link(flat[curIdx - 1], 'prev', PREV) : document.createElement('span'));
            pager.appendChild(curIdx < flat.length - 1 ? link(flat[curIdx + 1], 'next', NEXT) : document.createElement('span'));
            main.appendChild(pager);
          }
          q.addEventListener('input', function () {
            var v = q.value.trim().toLowerCase();
            groups.forEach(function (g) {
              var any = false;
              g.links.forEach(function (a) { var hit = !v || a.textContent.toLowerCase().indexOf(v) >= 0; a.style.display = hit ? '' : 'none'; any = any || hit; });
              g.d.style.display = any ? '' : 'none'; g.d.open = v ? any : g.open;
            });
          });
          document.body.insertBefore(side, main);
          var cur = side.querySelector('a.cur'); if (cur) cur.scrollIntoView({ block: 'center' });
          reveal();
        })();
        """
    }

    /// 読み込みの最初 (ページを描く前) に入れる: モダンの見た目を先に当て、目次を組み立て終わるまで本文を隠す。
    /// こうしないと、一瞬だけ元 (クラシック) の見た目が見えてしまう
    static var earlyJS: String {
        """
        (function () {
          var st = document.createElement('style');
          st.textContent = \(jsString(css + "\nhtml:not(.ttm-ready) body { visibility: hidden !important; }"));
          (document.head || document.documentElement).appendChild(st);
          // 何かで組み立てが止まっても、本文が隠れたままにならないように
          setTimeout(function () { document.documentElement.classList.add('ttm-ready'); }, 1500);
        })();
        """
    }

    static func jsString(_ s: String) -> String {
        let d = try? JSONSerialization.data(withJSONObject: [s])
        return d.flatMap { String(data: $0, encoding: .utf8) }.map { String($0.dropFirst().dropLast()) } ?? "\"\""
    }
    static func jsonString(_ o: Any) -> String {
        (try? JSONSerialization.data(withJSONObject: o)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
    }
}
