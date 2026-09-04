/* ==========================================================================
   DeckChrome — everything around the slides:
     * per-part accent theming (tints background, rail, headings, controls)
     * chapter rail on the left, with sub-dots for the current part
     * top-right context readout with a contextual affordance hint
     * Ctrl+K / "/" command palette to jump to any slide
     * "?" keyboard help
     * "D" annotation layer for drawing on a slide while presenting
   ========================================================================== */
window.DeckChrome = (function () {
  'use strict';

  /* The deck's parts, in order. Override per deck by setting window.DECK_PARTS
     in index.html BEFORE this script runs — `id` must match the data-part
     attribute on each <section>. Accents are picked to stay legible on the
     dark ground at projector gamma; if you swap them, check the rail and the
     .part pill, which use the accent as a foreground colour. */
  const PARTS = window.DECK_PARTS || [
    { id: 'intro',  label: 'Intro',    accent: '#8b5cf6', accent2: '#22d3ee' },
    { id: 'one',    label: 'Part one', accent: '#22d3ee', accent2: '#60a5fa' },
    { id: 'two',    label: 'Part two', accent: '#fbbf24', accent2: '#fb923c' },
    { id: 'three',  label: 'Part three', accent: '#fb7185', accent2: '#f472b6' },
    { id: 'four',   label: 'Part four', accent: '#34d399', accent2: '#22d3ee' }
  ];
  const partById = (id) => PARTS.find((p) => p.id === id) || PARTS[0];

  let slides = [];          // flat index: { h, v, title, part, el }
  const rail = document.getElementById('rail');
  const ctxPart = document.querySelector('#context [data-role="part"]');
  const ctxHint = document.querySelector('#context [data-role="hint"]');

  /* ---------------- slide index ---------------- */
  function buildIndex() {
    slides = [];
    Array.from(document.querySelectorAll('.reveal .slides > section')).forEach((sec, h) => {
      const kids = Array.from(sec.querySelectorAll(':scope > section'));
      const stack = kids.length ? kids : [sec];
      stack.forEach((el, v) => {
        slides.push({
          h, v: kids.length ? v : 0, el,
          part: el.dataset.part || sec.dataset.part || 'intro',
          title: title(el) || title(sec) || `Slide ${h + 1}`,
          interactive: el.hasAttribute('data-interactive')
        });
      });
    });
  }

  function title(el) {
    if (el.dataset.title) return el.dataset.title;
    const h = el.querySelector('h1, h2');
    return h ? h.textContent.trim().replace(/\s+/g, ' ') : '';
  }

  /* ---------------- accent theming ---------------- */
  function applyPart(partId) {
    const p = partById(partId);
    const r = document.documentElement.style;
    r.setProperty('--accent', p.accent);
    r.setProperty('--accent-2', p.accent2);
    ctxPart.textContent = p.label;
  }

  /* ---------------- chapter rail ---------------- */
  function buildRail() {
    rail.innerHTML = '';
    PARTS.forEach((p) => {
      const first = slides.findIndex((s) => s.part === p.id);
      if (first < 0) return;
      const group = document.createElement('div');
      group.className = 'chap-group';
      group.dataset.part = p.id;

      const btn = document.createElement('button');
      btn.className = 'chap';
      btn.innerHTML = `<span class="dot"></span><span class="txt">${p.label}</span>`;
      btn.addEventListener('click', () => Reveal.slide(slides[first].h, slides[first].v));
      group.appendChild(btn);

      const sub = document.createElement('div');
      sub.className = 'subdots';
      slides.filter((s) => s.part === p.id).forEach((s) => {
        const sd = document.createElement('button');
        sd.className = 'sd';
        sd.title = s.title;
        if (s.interactive) sd.classList.add('int');
        sd.addEventListener('click', () => Reveal.slide(s.h, s.v));
        sub.appendChild(sd);
      });
      group.appendChild(sub);
      rail.appendChild(group);
    });
  }

  function syncRail(current) {
    const part = current.part;
    rail.querySelectorAll('.chap-group').forEach((g) => {
      const on = g.dataset.part === part;
      g.classList.toggle('current', on);
      g.querySelector('.chap').setAttribute('aria-current', on ? 'true' : 'false');
      const inPart = slides.filter((s) => s.part === g.dataset.part);
      Array.from(g.querySelectorAll('.sd')).forEach((sd, i) => {
        sd.setAttribute('aria-current', on && inPart[i] === current ? 'true' : 'false');
        sd.classList.toggle('seen', slides.indexOf(inPart[i]) <= slides.indexOf(current));
      });
    });
  }

  /* ---------------- context hint ---------------- */
  /** Tells the presenter what this slide affords, so nothing needs memorising. */
  function syncHint(current) {
    const el = current.el;
    const bits = [];
    if (current.interactive) bits.push('B run · R reset');
    else if (el.querySelector('.code-step')) bits.push('→ steps through the code');
    const stack = el.closest('.slides > section');
    if (stack && stack.querySelectorAll(':scope > section').length > 1 && current.v === 0) {
      bits.push('↓ more');
    }
    ctxHint.textContent = bits.join('   ·   ');
  }

  /* ---------------- command palette ---------------- */
  function initPalette() {
    const overlay = document.getElementById('palette-overlay');
    const input = overlay.querySelector('[data-role="q"]');
    const list = overlay.querySelector('[data-role="results"]');
    let matches = [];
    let sel = 0;

    const score = (s, q) => {
      if (!q) return 0;
      const t = s.title.toLowerCase();
      const i = t.indexOf(q);
      if (i >= 0) return 100 - i;
      // loose subsequence match, so "gen sml" finds "The generator is this small"
      let pos = -1;
      for (const ch of q.replace(/\s/g, '')) {
        pos = t.indexOf(ch, pos + 1);
        if (pos < 0) return -1;
      }
      return 1;
    };

    function draw() {
      if (!matches.length) {
        list.innerHTML = '<div class="empty">No slide matches that.</div>';
        return;
      }
      list.innerHTML = matches.map((s, i) => {
        const p = partById(s.part);
        const n = slides.indexOf(s) + 1;
        return `<div class="item" data-i="${i}" aria-selected="${i === sel}">` +
          `<span class="no">${n}</span>` +
          `<span class="ttl">${s.title}</span>` +
          (s.interactive ? '<span class="badge">interactive</span>' : '') +
          `<span class="pt" style="color:${p.accent}">${p.label}</span></div>`;
      }).join('');
      list.querySelectorAll('.item').forEach((it) => {
        it.addEventListener('click', () => { sel = Number(it.dataset.i); go(); });
        it.addEventListener('mouseenter', () => {
          sel = Number(it.dataset.i);
          list.querySelectorAll('.item').forEach((x, i) => x.setAttribute('aria-selected', i === sel));
        });
      });
      const active = list.querySelector('[aria-selected="true"]');
      if (active) active.scrollIntoView({ block: 'nearest' });
    }

    function search() {
      const q = input.value.trim().toLowerCase();
      matches = q
        ? slides.map((s) => ({ s, k: score(s, q) })).filter((x) => x.k >= 0)
            .sort((a, b) => b.k - a.k).map((x) => x.s)
        : slides.slice();
      sel = 0;
      draw();
    }

    function go() {
      const s = matches[sel];
      close();
      if (s) Reveal.slide(s.h, s.v);
    }

    function open() {
      overlay.dataset.open = 'true';
      input.value = '';
      search();
      input.focus();
    }
    function close() { overlay.dataset.open = 'false'; input.blur(); }

    input.addEventListener('input', search);
    input.addEventListener('keydown', (e) => {
      if (e.key === 'ArrowDown') { sel = Math.min(matches.length - 1, sel + 1); draw(); e.preventDefault(); }
      else if (e.key === 'ArrowUp') { sel = Math.max(0, sel - 1); draw(); e.preventDefault(); }
      else if (e.key === 'Enter') { go(); e.preventDefault(); }
      else if (e.key === 'Escape') { close(); e.preventDefault(); }
      e.stopPropagation();
    });
    overlay.addEventListener('click', (e) => { if (e.target === overlay) close(); });

    return { open, close, isOpen: () => overlay.dataset.open === 'true' };
  }

  /* ---------------- help overlay ---------------- */
  function initHelp() {
    const overlay = document.getElementById('help-overlay');
    overlay.addEventListener('click', () => { overlay.dataset.open = 'false'; });
    return {
      toggle: () => { overlay.dataset.open = overlay.dataset.open === 'true' ? 'false' : 'true'; },
      close: () => { overlay.dataset.open = 'false'; },
      isOpen: () => overlay.dataset.open === 'true'
    };
  }

  /* ---------------- annotation layer ---------------- */
  function initAnnotate() {
    const canvas = document.getElementById('annotate');
    const badge = document.getElementById('draw-badge');
    const ctx = canvas.getContext('2d');
    const strokes = new Map();   // "h.v" -> [[{x,y},...], ...]
    let on = false, drawing = false, key = '0.0';

    function size() {
      const dpr = window.devicePixelRatio || 1;
      canvas.width = window.innerWidth * dpr;
      canvas.height = window.innerHeight * dpr;
      canvas.style.width = window.innerWidth + 'px';
      canvas.style.height = window.innerHeight + 'px';
      ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
      redraw();
    }

    function redraw() {
      ctx.clearRect(0, 0, window.innerWidth, window.innerHeight);
      const accent = getComputedStyle(document.documentElement)
        .getPropertyValue('--accent').trim() || '#8b5cf6';
      ctx.strokeStyle = accent;
      ctx.lineWidth = 4;
      ctx.lineJoin = ctx.lineCap = 'round';
      ctx.shadowColor = accent;
      ctx.shadowBlur = 10;
      (strokes.get(key) || []).forEach((path) => {
        if (path.length < 2) return;
        ctx.beginPath();
        ctx.moveTo(path[0].x, path[0].y);
        path.slice(1).forEach((p) => ctx.lineTo(p.x, p.y));
        ctx.stroke();
      });
    }

    function begin(e) {
      if (!on) return;
      drawing = true;
      if (!strokes.has(key)) strokes.set(key, []);
      strokes.get(key).push([{ x: e.clientX, y: e.clientY }]);
      canvas.setPointerCapture(e.pointerId);
    }
    function move(e) {
      if (!on || !drawing) return;
      const paths = strokes.get(key);
      paths[paths.length - 1].push({ x: e.clientX, y: e.clientY });
      redraw();
    }
    function end() { drawing = false; }

    canvas.addEventListener('pointerdown', begin);
    canvas.addEventListener('pointermove', move);
    canvas.addEventListener('pointerup', end);
    canvas.addEventListener('pointercancel', end);
    window.addEventListener('resize', size);
    size();

    return {
      toggle() {
        on = !on;
        canvas.dataset.on = on ? 'true' : 'false';
        badge.dataset.on = on ? 'true' : 'false';
      },
      clear() { strokes.delete(key); redraw(); },
      setSlide(h, v) { key = `${h}.${v}`; redraw(); },
      isOn: () => on
    };
  }

  /* ---------------- wiring ---------------- */
  function init() {
    buildIndex();
    buildRail();
    const palette = initPalette();
    const help = initHelp();
    const annotate = initAnnotate();

    function current() {
      const idx = Reveal.getIndices();
      return slides.find((s) => s.h === idx.h && s.v === (idx.v || 0)) || slides[0];
    }

    function onSlide() {
      const c = current();
      applyPart(c.part);
      syncRail(c);
      syncHint(c);
      annotate.setSlide(c.h, c.v);
      DeckCode.syncSteps(c.el);
      // interactive slides always start from a clean state
      const w = DeckWidgets.forSection(c.el);
      if (w) w.reset();
    }

    Reveal.on('slidechanged', onSlide);
    Reveal.on('fragmentshown', (e) => DeckCode.syncSteps(e.fragment.closest('section')));
    Reveal.on('fragmenthidden', (e) => DeckCode.syncSteps(e.fragment.closest('section')));
    Reveal.on('ready', onSlide);
    onSlide();

    document.addEventListener('keydown', (e) => {
      if (e.target.tagName === 'INPUT' || e.target.tagName === 'TEXTAREA') return;

      if (e.key === 'Escape') {
        if (palette.isOpen()) { palette.close(); e.stopPropagation(); e.preventDefault(); return; }
        if (help.isOpen()) { help.close(); e.stopPropagation(); e.preventDefault(); return; }
        return;
      }
      if ((e.ctrlKey || e.metaKey) && e.key.toLowerCase() === 'k') { palette.open(); e.preventDefault(); return; }
      if (e.ctrlKey || e.metaKey || e.altKey) return;

      switch (e.key) {
        case '/':
          palette.open(); e.preventDefault(); break;
        case '?':
          help.toggle(); e.preventDefault(); break;
        case 'd': case 'D':
          annotate.toggle(); e.preventDefault(); break;
        case 'c': case 'C':
          annotate.clear(); e.preventDefault(); break;
        case 'b': case 'B': {
          const w = DeckWidgets.forSection(current().el);
          if (w) { w.run(); e.preventDefault(); }
          break;
        }
        case 'r': case 'R': {
          const w = DeckWidgets.forSection(current().el);
          if (w) { w.reset(); e.preventDefault(); }
          break;
        }
      }
    }, true);
  }

  return { init };
})();
