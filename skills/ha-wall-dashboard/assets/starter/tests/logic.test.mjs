import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  isActive, tapAction, lockAction, defaultIcon, weatherIcon, climateView, climateTapAction, clampTarget,
  thresholdClass, mediaView, normalizeEvents, dedupeEvents, groupByDay, isMultiDay,
} from '../panels/logic.js';

test('isActive across domains', () => {
  assert.equal(isActive({ state: 'on' }), true);
  assert.equal(isActive({ state: 'open' }), true);
  assert.equal(isActive({ state: 'home' }), true);
  assert.equal(isActive({ state: 'off' }), false);
  assert.equal(isActive(null), false);
});

test('isActive with an explicit activeStates list (appliances)', () => {
  assert.equal(isActive({ state: 'run' }), false);
  assert.equal(isActive({ state: 'run' }, ['run', 'pause']), true);
  assert.equal(isActive({ state: 'stop' }, ['run', 'pause']), false);
  assert.equal(isActive({ state: 'on' }, ['run']), false);   // the list replaces the defaults
  assert.equal(isActive(null, ['run']), false);
});

test('tapAction picks the right service per domain', () => {
  assert.deepEqual(tapAction('light.a'), { domain: 'homeassistant', service: 'toggle' });
  assert.deepEqual(tapAction('scene.movie'), { domain: 'scene', service: 'turn_on' });
  assert.deepEqual(tapAction('button.doorbell'), { domain: 'button', service: 'press' });
  assert.deepEqual(lockAction({ state: 'locked' }), { domain: 'lock', service: 'unlock' });
  assert.deepEqual(lockAction({ state: 'unlocked' }), { domain: 'lock', service: 'lock' });
});

test('defaultIcon follows domain and device class', () => {
  assert.equal(defaultIcon('light.a', { state: 'on' }), 'lightbulb');
  assert.equal(defaultIcon('binary_sensor.d', { state: 'on', attributes: { device_class: 'door' } }), 'door-open');
  assert.equal(defaultIcon('sensor.x', { state: '1', attributes: {} }), 'gauge');
});

test('weatherIcon falls back for unknown conditions', () => {
  assert.equal(weatherIcon('sunny'), 'weather-sunny');
  assert.equal(weatherIcon('nonsense'), 'weather-cloudy');
});

test('climateView + clampTarget', () => {
  const v = climateView({ state: 'heat', attributes: { current_temperature: 20.1, temperature: 21, target_temp_step: 0.5, min_temp: 16, max_temp: 22 } });
  assert.equal(v.on, true);
  assert.equal(v.warm, true);
  assert.equal(v.icon, 'fire');
  assert.equal(clampTarget(21, 0.5, v), 21.5);
  assert.equal(clampTarget(21.5, 1, v), 22); // clamped to max
  assert.equal(climateView({ state: 'off', attributes: {} }).on, false);
  assert.equal(climateView({ state: 'unavailable', attributes: {} }).on, false);
});

test('thresholdClass: danger beats warn', () => {
  const item = { warnAbove: 2000, dangerAbove: 4000 };
  assert.equal(thresholdClass(1000, item), '');
  assert.equal(thresholdClass(2500, item), 'is-warn');
  assert.equal(thresholdClass(4500, item), 'is-danger');
  assert.equal(thresholdClass(null, item), '');
});

test('mediaView: idle states show nothing playing', () => {
  assert.equal(mediaView({ state: 'idle', attributes: {} }).idle, true);
  const v = mediaView({ state: 'playing', attributes: { media_title: 'T', media_artist: 'A' } });
  assert.deepEqual([v.playing, v.title, v.artist], [true, 'T', 'A']);
});

test('calendar: all-day dates are local, events grouped and sorted', () => {
  const raw = [
    { summary: 'Dentist', start: { dateTime: '2026-03-02T14:00:00' }, end: { dateTime: '2026-03-02T15:00:00' } },
    { summary: 'Holiday', start: { date: '2026-03-02' }, end: { date: '2026-03-03' } },
    { summary: 'Yoga', start: { dateTime: '2026-03-03T19:00:00' }, end: { dateTime: '2026-03-03T20:00:00' } },
  ];
  const events = normalizeEvents(raw, '#fff');
  assert.equal(events[1].start.getHours(), 0);
  const groups = groupByDay(events, new Date('2026-03-02T08:00:00'), 7);
  assert.equal(groups.length, 2);
  assert.deepEqual(groups[0].events.map((e) => e.title), ['Holiday', 'Dentist']);
  assert.equal(groups[1].offset, 1);
});

test('calendar: finished events drop off today, multi-day events span days', () => {
  const events = normalizeEvents([
    { summary: 'Breakfast', start: { dateTime: '2026-03-02T07:00:00' }, end: { dateTime: '2026-03-02T07:30:00' } },
    { summary: 'Camp', start: { date: '2026-03-02' }, end: { date: '2026-03-05' } },
  ]);
  const groups = groupByDay(events, new Date('2026-03-02T09:00:00'), 7);
  assert.deepEqual(groups.map((g) => g.events.map((e) => e.title).join()), ['Camp', 'Camp', 'Camp']);
  assert.equal(isMultiDay(events[1]), true);
});

test('calendar: a shared event from two calendars shows once', () => {
  const a = normalizeEvents([{ summary: 'Dinner', start: { dateTime: '2026-03-02T19:00:00' }, end: { dateTime: '2026-03-02T21:00:00' } }]);
  assert.equal(dedupeEvents([...a, ...a]).length, 1);
});

test('isMultiDay: a one-day event on a DST change day is still one day', () => {
  const [autumn, spring, camp] = normalizeEvents([
    { summary: 'Autumn', start: { date: '2026-10-25' }, end: { date: '2026-10-26' } },
    { summary: 'Spring', start: { date: '2026-03-29' }, end: { date: '2026-03-30' } },
    { summary: 'Camp', start: { date: '2026-10-24' }, end: { date: '2026-10-26' } },
  ]);
  assert.equal(isMultiDay(autumn), false);
  assert.equal(isMultiDay(spring), false);
  assert.equal(isMultiDay(camp), true);
});

test('climateView: range mode has no single target', () => {
  const v = climateView({ state: 'heat_cool', attributes: { current_temperature: 21, target_temp_low: 19, target_temp_high: 24 } });
  assert.equal(v.target, null);
  assert.deepEqual(v.range, [19, 24]);
});

test('climateTapAction: turn_on/off only when supported, else set_hvac_mode', () => {
  const s = (state, supported_features, hvac_modes = ['off', 'heat']) => ({ state, attributes: { supported_features, hvac_modes } });
  assert.deepEqual(climateTapAction(s('heat', 128 | 256)), { service: 'turn_off' });
  assert.deepEqual(climateTapAction(s('off', 128 | 256)), { service: 'turn_on' });
  assert.deepEqual(climateTapAction(s('heat', 1)), { service: 'set_hvac_mode', data: { hvac_mode: 'off' } });
  assert.deepEqual(climateTapAction(s('off', 1, ['off', 'cool', 'heat'])), { service: 'set_hvac_mode', data: { hvac_mode: 'cool' } });
  assert.equal(climateTapAction(s('off', 0, ['off'])), null);
});
