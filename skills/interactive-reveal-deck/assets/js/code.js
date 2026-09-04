/* ==========================================================================
   DeckCode — code rendering for the deck.

   Why a hand-rolled tokenizer instead of the highlight.js plugin:
     1. Code lives in <script type="text/template"> blocks. Script raw text is
        not parsed as markup, so generics (IEnumerable<T>, Vec<String>) and
        JSX/HTML snippets need no entity escaping and stay copy-pasteable
        straight out of the real source file.
     2. Widgets build code line-by-line at runtime; one renderer keeps the
        static slides and the animated panels visually identical.
     3. It emits one <span class="ln"> per line, which is what makes both the
        data-steps line highlighting and the staggered reveal possible.

   Add a language by writing a function of (src) -> highlighted HTML and
   registering it in LANGS. Token classes are .tok-k/t/s/n/c/f/a/p (keyword,
   type, string, number, comment, function, attribute, punctuation).
   ========================================================================== */
window.DeckCode = (function () {
  'use strict';

  /* ---------------- escaping ---------------- */
  const ESC = { '&': '&amp;', '<': '&lt;', '>': '&gt;' };
  const esc = (s) => s.replace(/[&<>]/g, (c) => ESC[c]);

  /* ---------------- C# ---------------- */
  const CS_KEYWORDS = new Set((
    'abstract as async await base bool break byte case catch char checked class const ' +
    'continue decimal default delegate do double else enum event explicit extern false ' +
    'finally fixed float for foreach get global goto if implicit in init int interface ' +
    'internal is lock long nameof namespace new not null object operator or out override ' +
    'params partial private protected public readonly record ref required return sbyte ' +
    'sealed set short sizeof stackalloc static string struct switch this throw true try ' +
    'typeof uint ulong unchecked unsafe ushort using value var virtual void volatile ' +
    'when where while with yield'
  ).split(' '));

  // One pass, ordered by precedence. Named groups keep the branches readable.
  const CS_RX = new RegExp([
    // comments
    '(?<com>\\/\\/[^\\n]*|\\/\\*[\\s\\S]*?\\*\\/)',
    // strings & chars (verbatim, interpolated, doubled quotes)
    '(?<str>[@$]{0,2}"(?:\\\\.|""|[^"\\\\\\n])*"|\'(?:\\\\.|[^\'\\\\])*\')',
    // a line-leading attribute list, incl. one level of nested parens
    '(?<=^[ \\t]*)(?<attr>\\[[A-Z][\\w.]*(?:\\((?:[^()]|\\([^()]*\\))*\\))?' +
      '(?:\\s*,\\s*[A-Z][\\w.]*(?:\\((?:[^()]|\\([^()]*\\))*\\))?)*\\])',
    // numbers
    '(?<num>\\b0x[0-9a-fA-F]+\\b|\\b\\d+(?:\\.\\d+)?[fdmuUlL]*\\b)',
    // identifiers — classified below
    '(?<id>[A-Za-z_][A-Za-z0-9_]*)',
    // operators / punctuation
    '(?<punct>[{}()\\[\\];,.:?!=<>+\\-*\\/%&|^~]+)'
  ].join('|'), 'gm');

  function csharp(src) {
    let out = '';
    let last = 0;
    CS_RX.lastIndex = 0;
    let m;
    while ((m = CS_RX.exec(src)) !== null) {
      if (m.index > last) out += esc(src.slice(last, m.index));
      const g = m.groups;
      const raw = esc(m[0]);
      if (g.com) out += `<span class="tok-c">${raw}</span>`;
      else if (g.str) out += `<span class="tok-s">${raw}</span>`;
      else if (g.attr) out += `<span class="tok-a">${raw}</span>`;
      else if (g.num) out += `<span class="tok-n">${raw}</span>`;
      else if (g.id) {
        const id = m[0];
        if (CS_KEYWORDS.has(id)) out += `<span class="tok-k">${raw}</span>`;
        else if (/^[A-Z]/.test(id)) out += `<span class="tok-t">${raw}</span>`;
        else if (src[CS_RX.lastIndex] === '(') out += `<span class="tok-f">${raw}</span>`;
        else out += raw;
      } else out += `<span class="tok-p">${raw}</span>`;
      last = CS_RX.lastIndex;
      if (m[0].length === 0) CS_RX.lastIndex++; // paranoia against zero-width loops
    }
    if (last < src.length) out += esc(src.slice(last));
    return out;
  }

  /* ---------------- markdown (for the SKILL.md slide) ---------------- */
  function markdown(src) {
    return src.split('\n').map((line) => {
      if (/^---\s*$/.test(line)) return `<span class="tok-c">${esc(line)}</span>`;
      if (/^#{1,6}\s/.test(line)) return `<span class="tok-t">${esc(line)}</span>`;
      let out = esc(line);
      // frontmatter "key:" and list markers
      out = out.replace(/^([a-z][\w-]*)(:)/, '<span class="tok-a">$1</span><span class="tok-p">$2</span>');
      out = out.replace(/^(\s*)([-*])(\s)/, '$1<span class="tok-p">$2</span>$3');
      // inline code and shouted MUST/NEVER
      out = out.replace(/`([^`]+)`/g, '<span class="tok-s">`$1`</span>');
      out = out.replace(/\b(NEVER|ALWAYS|MUST|DO NOT)\b/g, '<span class="tok-k">$1</span>');
      return out;
    }).join('\n');
  }

  /* ---------------- JSON (and JSONC) ----------------
     Config files are half of every integration talk, so keys get their own
     colour: a string followed by ':' is a key, anything else is a value.
     Line comments are allowed because the files people actually paste —
     VS Code settings.json, .mcp.json — are JSONC, not strict JSON. */
  const JSON_RX = new RegExp([
    '(?<com>\\/\\/[^\\n]*|\\/\\*[\\s\\S]*?\\*\\/)',
    '(?<key>"(?:\\\\.|[^"\\\\])*"(?=\\s*:))',
    '(?<str>"(?:\\\\.|[^"\\\\])*")',
    '(?<num>-?\\b\\d+(?:\\.\\d+)?(?:[eE][+-]?\\d+)?\\b)',
    '(?<lit>\\b(?:true|false|null)\\b)',
    '(?<punct>[{}\\[\\],:])'
  ].join('|'), 'gm');

  function json(src) {
    let out = '';
    let last = 0;
    JSON_RX.lastIndex = 0;
    let m;
    while ((m = JSON_RX.exec(src)) !== null) {
      if (m.index > last) out += esc(src.slice(last, m.index));
      const g = m.groups;
      const raw = esc(m[0]);
      if (g.com) out += `<span class="tok-c">${raw}</span>`;
      else if (g.key) out += `<span class="tok-a">${raw}</span>`;
      else if (g.str) out += `<span class="tok-s">${raw}</span>`;
      else if (g.num) out += `<span class="tok-n">${raw}</span>`;
      else if (g.lit) out += `<span class="tok-k">${raw}</span>`;
      else out += `<span class="tok-p">${raw}</span>`;
      last = JSON_RX.lastIndex;
      if (m[0].length === 0) JSON_RX.lastIndex++;
    }
    if (last < src.length) out += esc(src.slice(last));
    return out;
  }

  /* ---------------- JavaScript / TypeScript ----------------
     No regex-literal support on purpose: telling `/` division from a regex
     needs real parser state, and getting it wrong silently swallows the rest
     of the slide into a string. Slides rarely need one. */
  const JS_KEYWORDS = new Set((
    'as async await break case catch class const continue debugger default delete do ' +
    'else enum export extends false finally for from function get if implements import ' +
    'in instanceof interface let new null of private protected public readonly return ' +
    'satisfies set static super switch this throw true try type typeof undefined var ' +
    'void while yield'
  ).split(' '));

  const JS_RX = new RegExp([
    '(?<com>\\/\\/[^\\n]*|\\/\\*[\\s\\S]*?\\*\\/)',
    // template literals span newlines; splitTokenizedLines rebalances them
    '(?<str>`(?:\\\\.|[^`\\\\])*`|"(?:\\\\.|[^"\\\\\\n])*"|\'(?:\\\\.|[^\'\\\\\\n])*\')',
    '(?<num>\\b0x[0-9a-fA-F]+\\b|\\b\\d+(?:\\.\\d+)?\\b)',
    '(?<id>[A-Za-z_$][A-Za-z0-9_$]*)',
    '(?<punct>[{}()\\[\\];,.:?!=<>+\\-*\\/%&|^~]+)'
  ].join('|'), 'gm');

  function javascript(src) {
    let out = '';
    let last = 0;
    JS_RX.lastIndex = 0;
    let m;
    while ((m = JS_RX.exec(src)) !== null) {
      if (m.index > last) out += esc(src.slice(last, m.index));
      const g = m.groups;
      const raw = esc(m[0]);
      if (g.com) out += `<span class="tok-c">${raw}</span>`;
      else if (g.str) out += `<span class="tok-s">${raw}</span>`;
      else if (g.num) out += `<span class="tok-n">${raw}</span>`;
      else if (g.id) {
        const id = m[0];
        if (JS_KEYWORDS.has(id)) out += `<span class="tok-k">${raw}</span>`;
        else if (/^[A-Z]/.test(id)) out += `<span class="tok-t">${raw}</span>`;
        else if (src[JS_RX.lastIndex] === '(') out += `<span class="tok-f">${raw}</span>`;
        else out += raw;
      } else out += `<span class="tok-p">${raw}</span>`;
      last = JS_RX.lastIndex;
      if (m[0].length === 0) JS_RX.lastIndex++;
    }
    if (last < src.length) out += esc(src.slice(last));
    return out;
  }

  const LANGS = {
    csharp: csharp,
    json: json,
    js: javascript,
    ts: javascript,
    markdown: markdown,
    text: esc
  };
  const tokenize = (src, lang) => (LANGS[lang] || esc)(src);

  /* ---------------- helpers ---------------- */
  function dedent(src) {
    const lines = src.replace(/\t/g, '    ').split('\n');
    while (lines.length && !lines[0].trim()) lines.shift();
    while (lines.length && !lines[lines.length - 1].trim()) lines.pop();
    const indents = lines.filter((l) => l.trim()).map((l) => l.match(/^ */)[0].length);
    const cut = indents.length ? Math.min.apply(null, indents) : 0;
    return lines.map((l) => l.slice(cut)).join('\n');
  }

  // "1-3|6-9|11" -> [[1,3],[6,9],[11,11]]
  function parseSteps(spec) {
    return spec.split('|').map((chunk) => {
      const [a, b] = chunk.trim().split('-').map(Number);
      return [a, isNaN(b) ? a : b];
    });
  }

  /**
   * Render `src` into `el` as one <span class="ln"> per line.
   * opts.stagger: reveal lines progressively (ms between lines), else instant.
   */
  function paint(el, src, lang, opts) {
    opts = opts || {};
    const text = dedent(src);
    const html = tokenize(text, lang || 'text');
    // tokenize the whole block first (comments can span lines), then split
    el.innerHTML = splitTokenizedLines(html)
      .map((line, i) => `<span class="ln" data-i="${i + 1}">${line || ' '}</span>`)
      .join('');
    const lines = el.querySelectorAll('.ln');
    if (!opts.stagger) {
      lines.forEach((l) => l.classList.add('in'));
      return Promise.resolve(lines.length);
    }
    return new Promise((resolve) => {
      lines.forEach((l, i) => setTimeout(() => l.classList.add('in'), i * opts.stagger));
      setTimeout(() => resolve(lines.length), lines.length * opts.stagger + 60);
    });
  }

  /**
   * Split highlighted HTML on newlines while keeping spans balanced — a block
   * comment tokenized as one span would otherwise swallow the line breaks.
   */
  function splitTokenizedLines(html) {
    const out = [];
    let cur = '';
    const open = [];
    const rx = /<span class="([^"]+)">|<\/span>|\n|[^<\n]+|</g;
    let m;
    while ((m = rx.exec(html)) !== null) {
      const t = m[0];
      if (t === '\n') {
        out.push(cur + '</span>'.repeat(open.length));
        cur = open.map((c) => `<span class="${c}">`).join('');
      } else if (t === '</span>') {
        open.pop();
        cur += t;
      } else if (m[1]) {
        open.push(m[1]);
        cur += t;
      } else {
        cur += t;
      }
    }
    out.push(cur + '</span>'.repeat(open.length));
    return out;
  }

  /* ---------------- static slide code windows ---------------- */
  function chromeHtml(file, tag) {
    return '<div class="chrome">' +
      '<span class="dots"><i></i><i></i><i></i></span>' +
      `<span class="name">${file || ''}</span>` +
      (tag ? `<span class="tag">${tag}</span>` : '') +
      '</div>';
  }

  function render(root) {
    (root || document).querySelectorAll('figure[data-code]').forEach((fig) => {
      if (fig.dataset.rendered) return;
      const holder = fig.querySelector('script[type="text/template"]');
      const src = holder ? holder.textContent : '';
      if (holder) holder.remove();

      fig.insertAdjacentHTML('afterbegin', chromeHtml(fig.dataset.file, fig.dataset.tag));
      const box = document.createElement('div');
      box.className = 'codelines';
      fig.appendChild(box);
      paint(box, src, fig.dataset.lang);

      if (fig.dataset.steps) wireSteps(fig, box, parseSteps(fig.dataset.steps));
      fig.dataset.rendered = '1';
    });
  }

  /**
   * Turn data-steps into reveal fragments. Each fragment is an invisible marker
   * appended to the slide; showing it highlights that line range only, so the
   * arrow keys walk the reader through the interesting regions.
   */
  function wireSteps(fig, box, ranges) {
    const section = fig.closest('section');
    if (!section) return;
    ranges.forEach((r, i) => {
      const marker = document.createElement('span');
      marker.className = 'fragment code-step';
      marker.dataset.range = r.join('-');
      marker.style.display = 'none';
      marker.dataset.fragmentIndex = String(i);
      fig.appendChild(marker);
    });
    fig.stepRanges = ranges;
  }

  function applyStep(fig, range) {
    const lines = fig.querySelectorAll('.codelines .ln');
    lines.forEach((l) => l.classList.remove('hot'));
    if (!range) return;
    lines.forEach((l) => {
      const i = Number(l.dataset.i);
      if (i >= range[0] && i <= range[1]) l.classList.add('hot');
    });
  }

  /** Recompute the highlight from whichever markers reveal currently shows. */
  function syncSteps(section) {
    section.querySelectorAll('figure[data-code]').forEach((fig) => {
      if (!fig.stepRanges) return;
      const shown = Array.from(fig.querySelectorAll('.code-step.visible'));
      const last = shown[shown.length - 1];
      applyStep(fig, last ? last.dataset.range.split('-').map(Number) : null);
    });
  }

  return { render, paint, tokenize, dedent, syncSteps, splitTokenizedLines };
})();
