// Backward-compatible import path for the existing PWA. The actual protocol
// implementation is shared with Node in wire-protocol.js.
export {
  ProtocolError as LiteProtocolError,
  SERVER_MESSAGE_TYPES,
  parseServerMessage,
} from './wire-protocol.js';
