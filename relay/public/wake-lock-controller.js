export class WakeLockController {
  constructor({ requestLock = null, onStatus = () => {} } = {}) {
    this.requestLock = requestLock;
    this.onStatus = onStatus;
    this.generation = 0;
    this.desired = false;
    this.pending = null;
    this.lock = null;
    this.state = 'idle';
  }

  acquire() {
    this.desired = true;
    if (!this.requestLock) {
      this.#publish('unavailable');
      return Promise.resolve(null);
    }
    if (this.lock) return Promise.resolve(this.lock);
    if (this.pending?.generation === this.generation) return this.pending.promise;

    const generation = this.generation;
    let requested;
    try {
      requested = this.requestLock();
    } catch {
      this.#publish('denied');
      return Promise.resolve(null);
    }
    this.#publish('pending');
    const promise = Promise.resolve(requested).then(
      async (lock) => {
        if (generation !== this.generation || !this.desired) {
          try { await lock?.release(); } catch { /* already released */ }
          return null;
        }
        this.pending = null;
        this.lock = lock;
        this.#publish('active');
        lock?.addEventListener?.('release', () => {
          if (generation !== this.generation || this.lock !== lock) return;
          this.lock = null;
          this.#publish(this.desired ? 'released' : 'suspended');
        }, { once: true });
        return lock;
      },
      () => {
        if (generation === this.generation) {
          this.pending = null;
          this.#publish('denied');
        }
        return null;
      },
    );
    this.pending = { generation, promise };
    return promise;
  }

  async suspend() {
    this.desired = false;
    this.generation += 1;
    this.pending = null;
    const lock = this.lock;
    this.lock = null;
    this.#publish('suspended');
    try { await lock?.release(); } catch { /* already released */ }
  }

  #publish(state) {
    this.state = state;
    this.onStatus(Object.freeze({ state, generation: this.generation }));
  }
}
