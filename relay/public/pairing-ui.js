import { parseAndClearPairingFragment } from './pairing-link.js';

const IN_PROGRESS = new Set(['recovering', 'connecting', 'claiming', 'awaiting_approval', 'activating']);

const ERROR_COPY = Object.freeze({
  expired: 'This pairing link expired.',
  used: 'This pairing link was already used.',
  denied: 'Pairing was denied on the Mac.',
  replaced: 'This browser was replaced.',
  disconnected: 'The network connection was interrupted.',
  connection_failed: 'The network connection was interrupted.',
  connection_timeout: 'The relay did not answer. Try the pairing link again.',
  claim_timeout: 'The relay did not answer. Try the pairing link again.',
  storage_failed: 'This browser could not save pairing securely.',
  authentication_failed: 'The saved pairing could not be verified.',
  activation_failed: 'This browser could not finish pairing.',
  invalid_response: 'The relay returned an invalid pairing response.',
});

function parsePastedLink(raw, expectedHost) {
  let parsed;
  try { parsed = new URL(raw); } catch { return null; }
  return parseAndClearPairingFragment(parsed, { state: null, replaceState() {} }, expectedHost);
}

export function createPairingUI({
  elements,
  enabled,
  paired,
  expectedHost,
  readClipboard = () => navigator.clipboard.readText(),
  startPairing,
  cancelPairing,
  forgetPairing,
  lifecycleTarget = window,
}) {
  let activePhase = 'idle';
  let listenersActive = true;
  let operationGeneration = 0;

  elements.panel.hidden = !enabled || paired;
  elements.remote.hidden = enabled && !paired;
  elements.pairAgain.hidden = !enabled || !paired;
  elements.forget.hidden = !enabled || !paired;
  elements.message.setAttribute('aria-live', 'polite');
  elements.alert.setAttribute('role', 'alert');
  elements.code.setAttribute('aria-label', 'Confirmation code');

  function clearSensitiveUI() {
    elements.code.textContent = '';
    elements.code.hidden = true;
  }

  function showPairingHome() {
    if (!enabled) return;
    operationGeneration += 1;
    activePhase = 'idle';
    clearSensitiveUI();
    elements.panel.hidden = false;
    elements.remote.hidden = true;
    elements.alert.hidden = true;
    elements.heading.textContent = 'Pair this browser';
    elements.message.textContent = 'Open a pairing link from your Mac, or paste it here.';
    elements.paste.hidden = false;
    elements.cancel.hidden = true;
    elements.forget.disabled = false;
    elements.heading.focus();
  }

  function showRetainedPairing(message) {
    activePhase = 'forgetting';
    clearSensitiveUI();
    elements.panel.hidden = true;
    elements.remote.hidden = false;
    elements.alert.hidden = true;
    elements.pairedState.textContent = message;
    elements.pairAgain.hidden = !enabled;
    elements.forget.hidden = !enabled;
  }

  function beginOwned(parsed) {
    if (!enabled || !listenersActive || parsed?.pairingVersion !== 1 || typeof parsed.reference !== 'string') return false;
    clearSensitiveUI();
    elements.panel.hidden = false;
    elements.remote.hidden = true;
    elements.alert.hidden = true;
    elements.paste.hidden = true;
    elements.cancel.hidden = false;
    elements.forget.disabled = false;
    elements.heading.textContent = 'Pair this browser';
    elements.message.textContent = 'Claiming the pairing link…';
    elements.heading.focus();
    activePhase = 'connecting';
    startPairing(parsed.reference);
    return true;
  }

  function begin(parsed) {
    operationGeneration += 1;
    return beginOwned(parsed);
  }

  function startRecovery() {
    if (!enabled || !listenersActive) return false;
    operationGeneration += 1;
    clearSensitiveUI();
    elements.panel.hidden = false;
    elements.remote.hidden = true;
    elements.alert.hidden = true;
    elements.paste.hidden = true;
    elements.cancel.hidden = false;
    elements.forget.disabled = false;
    elements.heading.textContent = 'Reconnecting this browser';
    elements.message.textContent = 'Checking the saved pairing…';
    elements.heading.focus();
    activePhase = 'recovering';
    return true;
  }

  function showFailure(reason) {
    clearSensitiveUI();
    elements.alert.hidden = false;
    elements.alert.textContent = ERROR_COPY[reason] ?? 'Pairing could not be completed. Try again.';
    elements.message.textContent = '';
    elements.paste.hidden = false;
    elements.cancel.hidden = true;
  }

  function handleState(next) {
    if (!enabled || !listenersActive) return;
    if (activePhase === 'forgetting') return;
    activePhase = next.phase;
    elements.alert.hidden = true;
    if (next.phase !== 'awaiting_approval') clearSensitiveUI();

    switch (next.phase) {
      case 'recovering':
        elements.heading.textContent = 'Reconnecting this browser';
        elements.message.textContent = 'Checking the saved pairing…';
        break;
      case 'connecting':
      case 'claiming':
        elements.heading.textContent = 'Pair this browser';
        elements.message.textContent = 'Claiming the pairing link…';
        break;
      case 'awaiting_approval':
        elements.heading.textContent = 'Check the code on your Mac';
        elements.message.textContent = 'If both screens show this code, approve on the Mac.';
        elements.code.textContent = next.confirmationCode;
        elements.code.hidden = false;
        break;
      case 'activating':
        elements.heading.textContent = 'Finishing pairing';
        elements.message.textContent = 'Activating this browser…';
        break;
      case 'active':
        elements.panel.hidden = true;
        elements.remote.hidden = false;
        elements.pairedState.textContent = 'Paired with your Mac.';
        elements.pairAgain.hidden = false;
        elements.forget.hidden = false;
        break;
      case 'replaced':
        elements.panel.hidden = false;
        elements.remote.hidden = true;
        showFailure('replaced');
        break;
      case 'failed':
        elements.panel.hidden = false;
        elements.remote.hidden = true;
        showFailure(next.reason);
        break;
      case 'cancelled':
      case 'idle':
        showPairingHome();
        break;
      default:
        showFailure('unknown');
    }
  }

  async function consumeClipboard() {
    const generation = ++operationGeneration;
    let raw;
    try { raw = await readClipboard(); } catch {
      if (listenersActive && generation === operationGeneration) showFailure('invalid_link');
      return;
    }
    if (!listenersActive || generation !== operationGeneration) return;
    const parsed = parsePastedLink(raw, expectedHost);
    if (!parsed) { showFailure('invalid_link'); return; }
    beginOwned(parsed);
  }

  function onPaste(event) {
    event.preventDefault();
    operationGeneration += 1;
    const parsed = parsePastedLink(event.clipboardData?.getData('text') ?? '', expectedHost);
    if (!parsed) { showFailure('invalid_link'); return; }
    beginOwned(parsed);
  }

  function cancelInProgress() {
    if (!IN_PROGRESS.has(activePhase)) return;
    operationGeneration += 1;
    activePhase = 'cancelled';
    clearSensitiveUI();
    cancelPairing();
  }

  async function forget() {
    const generation = ++operationGeneration;
    showRetainedPairing('Forgetting this browser…');
    elements.pairAgain.disabled = true;
    elements.forget.disabled = true;
    let removed = false;
    try { removed = await forgetPairing(); } catch { removed = false; } finally {
      if (listenersActive && generation === operationGeneration) {
        elements.pairAgain.disabled = false;
        elements.forget.disabled = false;
      }
    }
    if (!listenersActive || generation !== operationGeneration) return;
    if (removed) {
      elements.pairAgain.hidden = true;
      elements.forget.hidden = true;
      showPairingHome();
    } else {
      showRetainedPairing('Could not forget this browser. Try again.');
      elements.pairAgain.disabled = false;
      elements.forget.disabled = false;
    }
  }

  const onKeyDown = (event) => {
    if (event.key === 'Escape') cancelInProgress();
  };
  const onPageHide = () => {
    operationGeneration += 1;
    cancelInProgress();
  };
  const onPairAgain = () => showPairingHome();
  const onCancel = () => { cancelInProgress(); showPairingHome(); };
  const onForget = () => { void forget(); };
  const onPasteButton = () => { void consumeClipboard(); };

  elements.paste.addEventListener('click', onPasteButton);
  elements.paste.addEventListener('paste', onPaste);
  elements.cancel.addEventListener('click', onCancel);
  elements.pairAgain.addEventListener('click', onPairAgain);
  elements.forget.addEventListener('click', onForget);
  lifecycleTarget.addEventListener('keydown', onKeyDown);
  lifecycleTarget.addEventListener('pagehide', onPageHide);

  if (enabled && !paired) showPairingHome();

  return Object.freeze({
    start: begin,
    startRecovery,
    handleState,
    showPairingHome,
    destroy() {
      if (!listenersActive) return;
      listenersActive = false;
      operationGeneration += 1;
      cancelInProgress();
      elements.paste.removeEventListener('click', onPasteButton);
      elements.paste.removeEventListener('paste', onPaste);
      elements.cancel.removeEventListener('click', onCancel);
      elements.pairAgain.removeEventListener('click', onPairAgain);
      elements.forget.removeEventListener('click', onForget);
      lifecycleTarget.removeEventListener('keydown', onKeyDown);
      lifecycleTarget.removeEventListener('pagehide', onPageHide);
    },
  });
}
