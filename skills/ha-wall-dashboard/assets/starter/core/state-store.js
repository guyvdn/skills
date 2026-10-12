// In-memory cache of HA entity states with a tiny per-entity pub/sub.
// Panels subscribe to the entity ids they care about; the live client feeds it
// the get_states snapshot and every state_changed event after that.
export class StateStore {
  constructor() {
    this.states = new Map();    // entity_id -> { entity_id, state, attributes, ... }
    this.listeners = new Map(); // entity_id -> Set<cb>
  }

  // Seed from a get_states result. Replaces the cache and notifies every
  // listener, so a reconnect repaints everything with fresh values.
  setAll(stateArray) {
    this.states = new Map();
    for (const s of stateArray) this.states.set(s.entity_id, s);
    for (const entityId of this.listeners.keys()) this._notify(entityId);
  }

  // Apply one state_changed event. new_state is null when an entity is removed.
  applyEvent(event) {
    const ns = event?.data?.new_state;
    if (!ns) return;
    this.states.set(ns.entity_id, ns);
    this._notify(ns.entity_id);
  }

  get(entityId) {
    return this.states.get(entityId) ?? null;
  }

  // Write a synthetic (non-HA) state and notify subscribers. Lets one panel
  // share a computed value with another, under a '_local.' prefix by convention.
  set(entityId, stateObj) {
    this.states.set(entityId, stateObj);
    this._notify(entityId);
  }

  // Register cb for each id and call it immediately with the cached value (or
  // null), so panels paint without waiting for a change. Returns unsubscribe.
  subscribe(entityIds, cb) {
    for (const id of entityIds) {
      if (!this.listeners.has(id)) this.listeners.set(id, new Set());
      this.listeners.get(id).add(cb);
      cb(this.get(id));
    }
    return () => {
      for (const id of entityIds) this.listeners.get(id)?.delete(cb);
    };
  }

  _notify(entityId) {
    const cbs = this.listeners.get(entityId);
    if (!cbs) return;
    const state = this.get(entityId);
    for (const cb of cbs) cb(state);
  }
}
