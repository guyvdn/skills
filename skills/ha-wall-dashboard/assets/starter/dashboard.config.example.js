// Everything that is specific to one home lives here. The wizard writes this
// file; after that, edit it by hand or ask the agent to. Reload the tablet
// after deploying.
//
// Layout: `columns` left to right. `width` is a relative share of the screen
// width, each panel's `size` a relative share of its column's height.
// Panel types and their options: references/panels.md in the skill.
export default {
  locale: 'en-GB',            // dates, numbers, built-in labels (en / nl / fr / de)
  theme: 'tron',              // or { day: 'daylight', night: 'tron' } to follow the sun
  themeOverrides: {},         // e.g. { '--accent': '#7CFFB2' }
  scale: 1,                   // all text and icons; 1.15 = 15 % bigger
  labels: {},                 // override a built-in string, e.g. { allClear: 'All shut' }

  columns: [
    {
      width: 1,
      panels: [
        { type: 'weather', size: 1, entity: 'weather.home', days: 5 },
        { type: 'climate', size: 1, items: [
          { entity: 'climate.living_room', name: 'Living' },
          { entity: 'climate.bedroom', name: 'Bedroom' },
        ] },
      ],
    },
    {
      width: 1.2,
      panels: [
        { type: 'clock', size: 1 },
        { type: 'calendar', size: 2, days: 7, calendars: [
          { entity: 'calendar.family', color: '#69F0AE' },
          { entity: 'calendar.holidays', color: '#FFD740', skipMultiDay: true },
        ] },
      ],
    },
    {
      width: 1,
      panels: [
        { type: 'toggles', size: 1, columns: 3, items: [
          { entity: 'light.living_room', name: 'Living', icon: 'sofa',
            value: { entity: 'sensor.living_room_temperature', decimals: 1 } },
          { entity: 'light.kitchen', name: 'Kitchen', icon: 'silverware-fork-knife' },
          { entity: 'switch.garden_lights', name: 'Garden', icon: 'lamp' },
        ] },
        { type: 'energy', size: 1, columns: 3, items: [
          { entity: 'sensor.electricity_import_total', name: 'Power', icon: 'flash', warnAbove: 15 },
          { entity: 'sensor.gas_total', name: 'Gas', icon: 'fire', decimals: 2 },
          { entity: 'sensor.power_now', name: 'Now', icon: 'gauge', today: false, decimals: 0,
            warnAbove: 2000, dangerAbove: 4000 },
        ] },
        { type: 'status', size: 1, title: 'Doors & windows', items: [
          { entity: 'binary_sensor.front_door', name: 'Front door' },
          { entity: 'binary_sensor.back_door', name: 'Back door' },
        ] },
      ],
    },
  ],
};
