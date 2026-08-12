import { PHASE } from './state.js';

export function composeCredentialAccess({ pairingEnabled, phase, elements }) {
  const manualNeeded = !pairingEnabled
    && [PHASE.MISSING_TOKEN, PHASE.TAKEN_OVER].includes(phase);
  if (!pairingEnabled) {
    elements.pairingPanel.hidden = true;
    elements.pairingGuidance.hidden = true;
  }
  elements.manualSettings.open = manualNeeded;
  elements.manualGuidance.hidden = !manualNeeded;
  elements.manualGuidance.textContent = phase === PHASE.TAKEN_OVER
    ? 'Replace the phone token to take control again.'
    : 'Enter the phone token from your Click Bridge Mac to connect this browser.';
}

export function composePairingStartup({
  pairingEnabled, hasPending, invitation, startInvitation,
}) {
  const invitationOwnsStartup = pairingEnabled && Boolean(invitation);
  if (invitationOwnsStartup) startInvitation(invitation);
  return Object.freeze({
    recoveryNeeded: pairingEnabled && hasPending && !invitationOwnsStartup,
  });
}
