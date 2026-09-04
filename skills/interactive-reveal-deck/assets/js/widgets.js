/* ==========================================================================
   DeckWidgets — the interactive-panel framework, plus two general-purpose
   widgets that work straight out of the box.

   THE CONTRACT. Every widget registers { run, reset } for its slide:
     * B runs it, R resets it, so a panel is driveable from a clicker with no
       mouse and no pointing at the screen.
     * Entering the slide always calls reset(), so a second pass through the
       deck behaves exactly like the first. Never rely on a widget's state
       surviving navigation.
     * A widget must be idempotent under repeated run(): guard with a `busy`
       flag if it animates, or a fast clicker double-tap desyncs it.

   TO ADD YOUR OWN, in a separate file loaded after this one:
     DeckWidgets.register('myThing', function (el) {
       const section = el.closest('section');
       function run()   { ... }
       function reset() { ... }
       reset();
       DeckWidgets.own(section, { run, reset });
     });
   then put <div data-widget="myThing"> on the slide. See
   references/widget-recipes.md for three more worked patterns.
   ========================================================================== */
window.DeckWidgets = (function () {
  'use strict';

  const registry = new Map();   // section -> { run, reset }
  const BUILDERS = {};

  const nf = (n) => Math.round(n).toLocaleString('en-US');
  const $ = (root, role) => root.querySelector(`[data-role="${role}"]`);
  const $$ = (root, role) => Array.from(root.querySelectorAll(`[data-role="${role}"]`));

  /* ======================================================================
     Widget: pipeline — "input goes in, generated output comes out"
     ----------------------------------------------------------------------
     Content lives in the slide, not here: one <script type="text/template">
     per side per variant. The output is revealed line by line, which reads as
     the tool doing work and gives you something to talk over.

       <div class="pipeline" data-widget="pipeline" data-lang="csharp">
         <!-- crossing languages? data-lang-in="csharp" data-lang-out="json" -->
         <figure class="code-window" data-role="input"> ...
           <div class="codelines" data-role="input-code"></div></figure>
         <div class="arrow">...</div>
         <figure class="code-window out" data-role="output"> ...
           <div class="codelines" data-role="output-code"></div>
           <div class="placeholder">nothing generated yet</div></figure>

         <script type="text/template" data-variant="Int" data-side="in">...</script>
         <script type="text/template" data-variant="Int" data-side="out">...</script>
       </div>

     Variant buttons are [data-kind="Int"] in the slide's toolbar; omit them
     for a single-variant panel. Switching variant resets the output, which is
     the whole point of the slide: one input change, a different whole output.
     ====================================================================== */
  function initPipeline(el) {
    const section = el.closest('section');
    const bar = section.querySelector('[data-widget="pipeline-toolbar"]');
    const inCode = $(el, 'input-code');
    const outCode = $(el, 'output-code');
    const out = $(el, 'output');
    const stats = $(section, 'stats');
    // input and output are often different languages -- the whole point of a
    // pipeline can be "source in, wire format out". data-lang sets both.
    const langIn = el.dataset.langIn || el.dataset.lang || 'text';
    const langOut = el.dataset.langOut || el.dataset.lang || 'text';
    const delay = Number(el.dataset.delay || 780);   // the "compiling" beat
    const stagger = Number(el.dataset.stagger || 24);

    // pull the templates out of the DOM once, so nothing re-parses mid-talk
    const src = {};
    el.querySelectorAll('script[type="text/template"]').forEach((t) => {
      const v = t.dataset.variant || 'default';
      (src[v] = src[v] || {})[t.dataset.side] = t.textContent;
      t.remove();
    });
    let kind = (bar && bar.querySelector('[data-kind][aria-selected="true"]')?.dataset.kind)
      || Object.keys(src)[0] || 'default';
    let busy = false;

    const paintInput = () => DeckCode.paint(inCode, (src[kind] || {}).in || '', langIn);

    function reset() {
      busy = false;
      el.classList.remove('running');
      out.classList.remove('done');
      outCode.innerHTML = '';
      if (stats) {
        stats.classList.remove('in');
        const n = $(stats, 'stat-lines');
        if (n) n.textContent = '0';
      }
      paintInput();
    }

    function run() {
      if (busy) return;
      busy = true;
      el.classList.add('running');
      out.classList.remove('done');
      outCode.innerHTML = '';
      if (stats) stats.classList.remove('in');
      setTimeout(() => {
        el.classList.remove('running');
        out.classList.add('done');
        DeckCode.paint(outCode, (src[kind] || {}).out || '', langOut, { stagger }).then((n) => {
          if (stats) {
            const c = $(stats, 'stat-lines');
            if (c) c.textContent = nf(n);
            stats.classList.add('in');
          }
          busy = false;
        });
      }, delay);
    }

    if (bar) {
      bar.querySelectorAll('[data-kind]').forEach((btn) => {
        btn.addEventListener('click', () => {
          bar.querySelectorAll('[data-kind]').forEach((b) => b.setAttribute('aria-selected', 'false'));
          btn.setAttribute('aria-selected', 'true');
          kind = btn.dataset.kind;
          reset();
        });
      });
      const b = $(bar, 'build'); if (b) b.addEventListener('click', run);
      const r = $(bar, 'reset'); if (r) r.addEventListener('click', reset);
    }

    reset();
    registry.set(section, { run, reset });
  }

  /* ======================================================================
     Widget: calc — one slider, several derived numbers moving together
     ----------------------------------------------------------------------
     Declarative: each readout carries an expression of `n`, the slider value.
     No formulas in here, so the same widget serves any "what does this cost
     at scale" slide.

       <input type="range" min="1" max="40" value="6" data-role="slider">

       <span data-calc="n * 48"></span>                    -> 288
       <span data-calc="42 + n" data-fmt="int"></span>      -> 48
       <span data-calc="1 - Math.pow(0.97, n)" data-fmt="pct"></span>  -> 17%
       <span data-calc="n" data-fmt="raw"></span>           -> 6

       <span class="bar-fill" data-bar="n * 48"></span>
       <span class="bar-fill" data-bar="42 + n"></span>
       ^ widths are normalised across every [data-bar] in the widget, so the
         two curves stay comparable as the slider moves.

     If the numbers are modelled rather than measured, SAY SO in the speaker
     notes. An audience will ask, and "illustrative" is a fine answer only if
     you offer it first.
     ====================================================================== */
  const FMT = {
    int: nf,
    raw: (v) => String(Math.round(v)),
    pct: (v) => Math.round(v * 100) + '%',
    pct100: (v) => Math.round(v) + '%',
    fixed1: (v) => v.toFixed(1)
  };

  function initCalc(el) {
    const section = el.closest('section');
    const slider = $(el, 'slider');
    if (!slider) return;
    const initial = slider.value;

    // compile each expression once — not on every input event
    const compile = (node, attr) => ({
      node,
      fmt: FMT[node.dataset.fmt || 'int'] || FMT.int,
      fn: new Function('n', 'return (' + node.dataset[attr] + ');')
    });
    const readouts = Array.from(el.querySelectorAll('[data-calc]')).map((x) => compile(x, 'calc'));
    const bars = Array.from(el.querySelectorAll('[data-bar]')).map((x) => compile(x, 'bar'));

    function update() {
      const n = Number(slider.value);
      const span = Number(slider.max) - Number(slider.min);
      slider.style.setProperty('--pct',
        (span ? (n - Number(slider.min)) / span * 100 : 0) + '%');

      readouts.forEach((r) => { r.node.textContent = r.fmt(r.fn(n)); });
      const vals = bars.map((b) => Math.max(0, b.fn(n)));
      const max = Math.max.apply(null, vals.concat([1]));
      bars.forEach((b, i) => { b.node.style.width = (vals[i] / max * 100) + '%'; });
    }

    slider.addEventListener('input', update);
    update();

    // B/R still have to mean something here, so they step and rewind the slider
    const step = Number(el.dataset.keyStep || 8);
    registry.set(section, {
      run: () => {
        slider.value = Math.min(Number(slider.max), Number(slider.value) + step);
        update();
      },
      reset: () => { slider.value = initial; update(); }
    });
  }

  /* ====================================================================== */
  BUILDERS.pipeline = initPipeline;
  BUILDERS.calc = initCalc;

  function init() {
    document.querySelectorAll('[data-widget]').forEach((el) => {
      const b = BUILDERS[el.dataset.widget];
      if (b) b(el);
    });
  }

  return {
    init,
    /** Register a widget builder before DeckWidgets.init() runs. */
    register: (name, builder) => { BUILDERS[name] = builder; },
    /** A widget claims its slide's B/R keys. */
    own: (section, api) => registry.set(section, api),
    forSection: (section) => registry.get(section) || null,
    helpers: { nf, $, $$ }
  };
})();
