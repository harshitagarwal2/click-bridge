export class FakeScheduler {
  constructor(now = 0) {
    this.now = now;
    this.nextId = 1;
    this.tasks = new Map();
  }

  setTimeout = (callback, delay) => {
    const id = this.nextId++;
    this.tasks.set(id, { at: this.now + delay, callback });
    return id;
  };

  clearTimeout = (id) => {
    this.tasks.delete(id);
  };

  advance(ms) {
    const target = this.now + ms;
    while (true) {
      const due = [...this.tasks.entries()]
        .filter(([, task]) => task.at <= target)
        .sort((a, b) => a[1].at - b[1].at || a[0] - b[0])[0];
      if (!due) break;
      const [id, task] = due;
      this.tasks.delete(id);
      this.now = task.at;
      task.callback();
    }
    this.now = target;
  }
}

export class FakeSocket {
  constructor() {
    this.readyState = 0;
    this.sent = [];
    this.closed = [];
  }

  send(raw) {
    this.sent.push(JSON.parse(raw));
  }

  close(code, reason) {
    this.closed.push({ code, reason });
    this.readyState = 3;
  }

  open() {
    this.readyState = 1;
    this.onopen?.();
  }

  message(data) {
    this.onmessage?.({ data });
  }

  serverClose() {
    this.readyState = 3;
    this.onclose?.({ code: 1006 });
  }
}

export const VALID_TOKEN = 'a'.repeat(64);
export const ID = '018f63f5-6f3d-7d21-88bc-9ef561f030de';
