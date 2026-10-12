// Now playing on one media player, with transport and volume buttons.
// Config: { type: 'media', entity: 'media_player.living', name? }
import { iconSvg } from '../core/icons.js';
import { mediaView } from './logic.js';

export const card = true;

export function render(el, cfg, { store, client, baseUrl, t }) {
  el.classList.add('media');
  const art = document.createElement('div'); art.className = 'media-art';
  const info = document.createElement('div'); info.className = 'media-info';
  const title = document.createElement('div'); title.className = 'media-title';
  const artist = document.createElement('div'); artist.className = 'media-artist';
  const source = document.createElement('div'); source.className = 'media-source';
  info.append(title, artist, source);

  const controls = document.createElement('div'); controls.className = 'media-controls';
  const target = { entity_id: cfg.entity };
  const btn = (icon, service) => {
    const b = document.createElement('button');
    b.type = 'button'; b.className = 'media-btn';
    b.innerHTML = iconSvg(icon); // trusted constant SVG
    b.addEventListener('click', () => client.callService('media_player', service, target));
    controls.append(b);
    return b;
  };
  btn('volume-minus', 'volume_down');
  btn('skip-previous', 'media_previous_track');
  const playPause = btn('play', 'media_play_pause');
  btn('skip-next', 'media_next_track');
  btn('volume-plus', 'volume_up');

  el.append(art, info, controls);

  store.subscribe([cfg.entity], (s) => {
    const v = mediaView(s);
    el.classList.toggle('is-playing', v.playing);
    title.textContent = v.idle ? t('nothingPlaying') : (v.title || s?.attributes?.friendly_name || '');
    artist.textContent = v.idle ? '' : v.artist;
    source.textContent = cfg.name ?? s?.attributes?.friendly_name ?? '';
    playPause.innerHTML = iconSvg(v.playing ? 'pause' : 'play'); // trusted constant SVG
    // entity_picture is a same-origin /api/media_player_proxy/... path that
    // already carries its own access token, so a plain <img> can load it.
    if (v.picture && !v.idle) {
      const src = v.picture.startsWith('http') ? v.picture : baseUrl + v.picture;
      if (art.dataset.src !== src) {
        art.dataset.src = src;
        art.replaceChildren(Object.assign(document.createElement('img'), { src, alt: '' }));
      }
    } else {
      art.dataset.src = '';
      art.innerHTML = iconSvg('music-note'); // trusted constant SVG
    }
  });
}
