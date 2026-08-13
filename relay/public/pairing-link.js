const MAX_LINK_BYTES = 512;
const LINK_FRAGMENT = /^#v=1&r=([A-Za-z0-9_-]{43})$/;
const PAIRING_PATH = /^\/pair(?:\/web)?(?:\/([A-Za-z0-9_-]{22}))?$/;
const encoder = new TextEncoder();

function isCanonicalReference(reference) {
  try {
    const standard = reference.replaceAll('-', '+').replaceAll('_', '/') + '=';
    const bytes = Uint8Array.from(atob(standard), (character) => character.charCodeAt(0));
    if (bytes.byteLength !== 32) return false;
    const canonical = btoa(String.fromCharCode(...bytes))
      .replaceAll('+', '-')
      .replaceAll('/', '_')
      .replace(/=+$/, '');
    return canonical === reference;
  } catch {
    return false;
  }
}

export function parseAndClearPairingFragment(location, history, expectedHost) {
  const rawHref = location.href;
  const rawFragment = location.hash;
  const scrubbedPath = `${location.pathname}${location.search}`;
  history.replaceState(history.state, '', scrubbedPath);

  const fragmentIndex = rawHref.indexOf('#');
  const preFragmentHref = fragmentIndex === -1 ? rawHref : rawHref.slice(0, fragmentIndex);
  const pairingPath = PAIRING_PATH.exec(location.pathname);
  const canonicalHref = `https://${expectedHost}${location.pathname}`;

  if (encoder.encode(rawHref).byteLength > MAX_LINK_BYTES
    || preFragmentHref !== canonicalHref
    || location.protocol !== 'https:'
    || location.host !== expectedHost
    || !pairingPath
    || location.search !== '') return null;

  const match = LINK_FRAGMENT.exec(rawFragment);
  if (!match || !isCanonicalReference(match[1])) return null;
  return { pairingVersion: 1, reference: match[1] };
}
