// Panel type -> module. Static imports on purpose: the deploy script can only
// cache-bust literal `from './x.js'` imports, never a dynamic import(`./${type}.js`).
// A new panel type = one module in this folder + one line here.
import * as clock from './clock.js';
import * as weather from './weather.js';
import * as calendar from './calendar.js';
import * as toggles from './toggles.js';
import * as climate from './climate.js';
import * as sensors from './sensors.js';
import * as media from './media.js';
import * as status from './status.js';

export const PANELS = {
  clock, weather, calendar, toggles, climate, sensors, energy: sensors, media, status,
};
