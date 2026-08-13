export const BRIDGE_REGISTRY_SCHEMA_VERSION = 2;
export const MAX_ACTIVE_PHONES = 8;

const HEX_64 = /^[0-9a-f]{64}$/;
const DEVICE_ID = /^[A-Za-z0-9_-]{16,64}$/;
const PHONE_STATUSES = new Set(['active', 'revoked']);
const BRIDGE_FIELDS = ['macVerifier', 'phones', 'registryRevision', 'schemaVersion'];
const PHONE_FIELDS = ['credentialVersion', 'deviceId', 'label', 'status', 'verifier'];

function exactFields(value, fields) {
  return Object.keys(value).sort().join('\0') === fields.join('\0');
}

function validLabel(label) {
  return typeof label === 'string' && label.length >= 1 && label.length <= 64
    && label === label.trim() && !/[\u0000-\u001f\u007f]/.test(label);
}

function clonePhone(phone) {
  return Object.freeze({
    deviceId: phone.deviceId,
    label: phone.label,
    credentialVersion: phone.credentialVersion,
    verifier: phone.verifier,
    status: phone.status,
  });
}

function freezeBridge(bridge) {
  return Object.freeze({
    schemaVersion: BRIDGE_REGISTRY_SCHEMA_VERSION,
    macVerifier: bridge.macVerifier,
    registryRevision: bridge.registryRevision,
    phones: Object.freeze(bridge.phones.map(clonePhone)),
  });
}

export function validateBridgeRecord(value) {
  if (typeof value !== 'object' || value === null || Array.isArray(value)
      || !exactFields(value, BRIDGE_FIELDS)
      || value.schemaVersion !== BRIDGE_REGISTRY_SCHEMA_VERSION
      || typeof value.macVerifier !== 'string' || !HEX_64.test(value.macVerifier)
      || !Number.isSafeInteger(value.registryRevision) || value.registryRevision < 0
      || !Array.isArray(value.phones)) {
    throw new TypeError('invalid bridge registry record');
  }
  const deviceIds = new Set();
  const credentialVersions = new Set();
  let activeCount = 0;
  for (const phone of value.phones) {
    if (typeof phone !== 'object' || phone === null || Array.isArray(phone)
        || !exactFields(phone, PHONE_FIELDS)
        || typeof phone.deviceId !== 'string' || !DEVICE_ID.test(phone.deviceId)
        || !validLabel(phone.label)
        || !Number.isSafeInteger(phone.credentialVersion) || phone.credentialVersion < 0
        || typeof phone.verifier !== 'string' || !HEX_64.test(phone.verifier)
        || !PHONE_STATUSES.has(phone.status)
        || deviceIds.has(phone.deviceId) || credentialVersions.has(phone.credentialVersion)) {
      throw new TypeError('invalid bridge registry record');
    }
    deviceIds.add(phone.deviceId);
    credentialVersions.add(phone.credentialVersion);
    if (phone.status === 'active') activeCount += 1;
  }
  if (activeCount > MAX_ACTIVE_PHONES) throw new TypeError('invalid bridge registry record');
  return freezeBridge(value);
}

export function createBridgeRecord({ macVerifier, phones = [], registryRevision = 0 }) {
  return validateBridgeRecord({
    schemaVersion: BRIDGE_REGISTRY_SCHEMA_VERSION,
    macVerifier,
    registryRevision,
    phones,
  });
}

export function encodeBridgeRecord(bridge) {
  return `${JSON.stringify(validateBridgeRecord(bridge))}\n`;
}

export function latestCredentialVersion(bridge) {
  return bridge.phones.reduce(
    (latest, phone) => Math.max(latest, phone.credentialVersion),
    0,
  );
}

export function bridgeSnapshot(bridge) {
  const activePhones = bridge.phones.filter((phone) => phone.status === 'active');
  return Object.freeze({
    schemaVersion: BRIDGE_REGISTRY_SCHEMA_VERSION,
    registryRevision: bridge.registryRevision,
    enrolledCount: activePhones.length,
    activePhoneCredentialVersion: latestCredentialVersion(bridge),
    phones: Object.freeze(activePhones.map((phone) => Object.freeze({
      deviceId: phone.deviceId,
      label: phone.label,
      credentialVersion: phone.credentialVersion,
      status: phone.status,
    }))),
  });
}

export function authenticatePhone(bridge, verifier, crypto) {
  if (typeof verifier !== 'string' || !HEX_64.test(verifier)) return null;
  for (const phone of bridge.phones) {
    if (phone.status !== 'active') continue;
    if (crypto.timingSafeEqual(Buffer.from(verifier, 'hex'), Buffer.from(phone.verifier, 'hex'))) {
      return Object.freeze({
        deviceId: phone.deviceId,
        credentialVersion: phone.credentialVersion,
      });
    }
  }
  return null;
}

export function isPhoneActive(bridge, deviceId, credentialVersion) {
  return bridge.phones.some((phone) => phone.status === 'active'
    && phone.deviceId === deviceId && phone.credentialVersion === credentialVersion);
}

export function hasActiveCredentialVersion(bridge, credentialVersion) {
  return bridge.phones.some((phone) => phone.status === 'active'
    && phone.credentialVersion === credentialVersion);
}

export function addPhone(bridge, { deviceId, label = 'Phone', credentialVersion, verifier }) {
  if (bridge.phones.filter((phone) => phone.status === 'active').length >= MAX_ACTIVE_PHONES) {
    throw new RangeError('active phone capacity reached');
  }
  const next = {
    schemaVersion: BRIDGE_REGISTRY_SCHEMA_VERSION,
    macVerifier: bridge.macVerifier,
    registryRevision: bridge.registryRevision + 1,
    phones: [...bridge.phones, {
      deviceId, label, credentialVersion, verifier, status: 'active',
    }],
  };
  return validateBridgeRecord(next);
}

export function renamePhone(bridge, { deviceId, label }) {
  const index = bridge.phones.findIndex((phone) => phone.deviceId === deviceId);
  if (index < 0 || bridge.phones[index].status !== 'active') throw new RangeError('phone unavailable');
  if (!validLabel(label)) throw new TypeError('invalid phone label');
  const phones = [...bridge.phones];
  phones[index] = { ...phones[index], label };
  return validateBridgeRecord({
    schemaVersion: BRIDGE_REGISTRY_SCHEMA_VERSION,
    macVerifier: bridge.macVerifier,
    registryRevision: bridge.registryRevision + 1,
    phones,
  });
}

export function revokePhone(bridge, { deviceId }) {
  const index = bridge.phones.findIndex((phone) => phone.deviceId === deviceId);
  if (index < 0) throw new RangeError('phone unavailable: unknown_device');
  if (bridge.phones[index].status !== 'active') throw new RangeError('phone unavailable: already_revoked');
  const phones = [...bridge.phones];
  phones[index] = { ...phones[index], status: 'revoked' };
  return validateBridgeRecord({
    schemaVersion: BRIDGE_REGISTRY_SCHEMA_VERSION,
    macVerifier: bridge.macVerifier,
    registryRevision: bridge.registryRevision + 1,
    phones,
  });
}
