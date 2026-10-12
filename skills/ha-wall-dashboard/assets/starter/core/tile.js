// Shared tile: a fixed 4-row grid (corners / centerpiece / value / name), so
// every tile on the wall lines up by construction whatever it shows.
export function createTile({ interactive = false } = {}) {
  const el = document.createElement(interactive ? 'button' : 'div');
  if (interactive) el.type = 'button';
  el.className = 'tile';

  const top = document.createElement('div'); top.className = 'tile-top';
  const topLeft = document.createElement('span'); topLeft.className = 'tile-tl';
  const topRight = document.createElement('span'); topRight.className = 'tile-tr';
  top.append(topLeft, topRight);

  const center = document.createElement('div'); center.className = 'tile-center';
  const value = document.createElement('div'); value.className = 'tile-value';
  const name = document.createElement('div'); name.className = 'tile-name';

  el.append(top, center, value, name);

  // Names shrink to fit instead of truncating: "Woonkamer" or "Slaapkamer" in
  // a 3-wide grid on a 1280 px tablet would otherwise end in "…", and the
  // workaround — renaming rooms to fit — is worse than slightly smaller type.
  // Values get the same treatment ("20.6° / 21.5°" in a monospace theme).
  fitText(name);
  fitText(value);
  const setName = (text) => {
    if (name.textContent === text) return;
    name.textContent = text;
    fit(name);
  };
  const fitValue = () => fit(value); // call after changing the value's content
  return { el, top, topLeft, topRight, center, value, name, setName, fitValue };
}

// Shrink an element's font until its text fits on one line, down to 65 % of
// the CSS size; past that the ellipsis takes over. Refits whenever the
// element is resized (first layout, rotation, a config scale change).
const MIN_FIT = 0.65;
function fit(el) {
  el.style.fontSize = '';
  if (!el.clientWidth) return; // not laid out yet; the ResizeObserver will call again
  const base = parseFloat(getComputedStyle(el).fontSize);
  let f = 1;
  while (el.scrollWidth > el.clientWidth && f > MIN_FIT) {
    f -= 0.05;
    el.style.fontSize = `${base * f}px`;
  }
}

// Everything being fitted, so a font or theme change can refit it all: the
// first fit may be measured with the fallback font (font-display: swap), and
// a day/night theme switch can change the font family entirely.
const fitted = new Set();
let refitArmed = false;
function armRefitAll() {
  if (refitArmed || typeof document === 'undefined') return;
  refitArmed = true;
  const refitAll = () => fitted.forEach(fit);
  document.fonts?.addEventListener?.('loadingdone', refitAll);
  document.fonts?.ready.then(refitAll);
  new MutationObserver(() => requestAnimationFrame(refitAll))
    .observe(document.documentElement, { attributes: true, attributeFilter: ['data-theme', 'style'] });
}

function fitText(el) {
  if (typeof ResizeObserver === 'undefined') return;
  fitted.add(el);
  armRefitAll();
  let lastWidth = 0;
  new ResizeObserver(([entry]) => {
    const w = Math.round(entry.contentRect.width);
    if (w === lastWidth) return; // our own font change doesn't alter the width; avoid loops
    lastWidth = w;
    fit(el);
  }).observe(el);
}

// A grid of tiles. Rows MUST be minmax(0, 1fr), not 1fr: a tile's min-content
// height (icon + text rows) is taller than a small cell, and plain 1fr keeps
// that floor, so tiles overflow their panel instead of shrinking into it.
export function createTileGrid(columns, count) {
  const grid = document.createElement('div');
  grid.className = 'tile-grid';
  const cols = Math.max(1, Math.min(columns, count || 1));
  grid.style.gridTemplateColumns = `repeat(${cols}, minmax(0, 1fr))`;
  return grid;
}
