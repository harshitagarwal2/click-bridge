export function createRuntimeScheduler(runtime) {
  return {
    setTimeout: (callback, delay) => runtime.setTimeout(callback, delay),
    clearTimeout: (timer) => runtime.clearTimeout(timer),
  };
}
