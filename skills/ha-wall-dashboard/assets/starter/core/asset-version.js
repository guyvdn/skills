// Cache-busting for assets whose URL is built at runtime (images, JSON).
//
// HA serves /local/ with a 31-day Cache-Control. The deploy script stamps
// ?v=TIMESTAMP onto literal JS imports and the stylesheet link, but cannot see
// a URL assembled in code — so a replaced image would stay stale on the tablet
// for a month. Import this module (with a literal relative import) from the
// panel that builds such a URL: the deploy stamps that import like any other,
// so this module's own import.meta.url carries the deploy version. Nothing in
// the starter needs it yet; it's here for panels that load images or JSON.
const V = new URL(import.meta.url).searchParams.get('v');

export const assetUrl = (path) => (V ? `${path}?v=${V}` : path);
