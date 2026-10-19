// Generates test/fixtures/vectors.json with the TypeScript SDK (1.5.0), so the
// Dart tests check byte-for-byte parity with it.
//
//   cd sdk/typescript && npm install && npm run build
//   node ../dart/catzconnect/tool/gen_vectors.mjs
//
// It drives the real TS SDK (dist/index.mjs, dist/push.mjs) with a fake fetch,
// a fixed nonce (randombytes_buf patched on the same libsodium instance) and a
// fixed Date.now().
import { createHmac } from "node:crypto";
import { writeFileSync, mkdirSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const tsDir = resolve(here, "../../../typescript");
const imp = (p) => import(pathToFileURL(join(tsDir, p)).href);

// The same module instance dist/*.mjs imports (package "exports" → import).
const sodium = (await imp("node_modules/libsodium-wrappers-sumo/dist/modules-sumo-esm/libsodium-wrappers.mjs")).default;
await sodium.ready;
const ts = await imp("dist/index.mjs");

const b64 = (u) => Buffer.from(u).toString("base64");
const fromB64 = (s) => new Uint8Array(Buffer.from(s, "base64"));

// ── fixed keys (the Go/Rust interop keys: [7;32] client, [9;32] server) ──
const clientPriv = new Uint8Array(32).fill(7);
const serverPriv = new Uint8Array(32).fill(9);
const clientPub = sodium.crypto_scalarmult_base(clientPriv);
const serverPub = sodium.crypto_scalarmult_base(serverPriv);
const env = { api_key: "  live_test_key\n", private_key: b64(clientPriv), server_public_key: b64(serverPub) };

const FIXED_NONCE = Uint8Array.from({ length: 12 }, (_, i) => i + 1);
const FIXED_TS = 1760745600000;
const realRandom = sodium.randombytes_buf.bind(sodium);
sodium.randombytes_buf = (n) => (n === 12 ? FIXED_NONCE.slice() : realRandom(n));
Date.now = () => FIXED_TS;

function serverKey() {
  const shared = sodium.crypto_scalarmult(serverPriv, clientPub);
  const master = sodium.crypto_generichash(32, shared, null);
  const label = sodium.from_string("CONNECT-@-2026-HS-@-CATZ");
  return sodium.crypto_generichash(32, new Uint8Array([...master, ...label]), null);
}
const KEY = serverKey();
function serverOpen(body) {
  const plain = sodium.crypto_aead_chacha20poly1305_ietf_decrypt(null, fromB64(body.ciphertext), null, fromB64(body.nonce), KEY);
  return sodium.to_string(plain);
}
function serverSeal(obj, nonce) {
  const ct = sodium.crypto_aead_chacha20poly1305_ietf_encrypt(sodium.from_string(JSON.stringify(obj)), null, null, nonce, KEY);
  return { nonce: b64(nonce), ciphertext: b64(ct) };
}

let seen = [];
function mockFetch(status, json) {
  seen = [];
  globalThis.fetch = async (url, init) => {
    const body = JSON.parse(init.body);
    seen.push({ url, headers: init.headers, body, plaintext: serverOpen(body) });
    const text = typeof json === "string" ? json : JSON.stringify(json);
    return { ok: status >= 200 && status < 300, status, text: async () => text, json: async () => JSON.parse(text) };
  };
}
process.env.CATZCONNECT_BASE_URL = "https://api.test/";

// Payload keys in the order of the Dart SendPayload.toJson (= types.ts order).
const ORDER = ["to", "otp", "subject", "body", "title", "data", "image", "link", "device_key", "external_user_id",
  "gateway", "sender", "dlt_template_id", "provider"];
const canon = (input) => {
  const p = {};
  for (const k of ORDER) if (input.payload && input.payload[k] !== undefined) p[k] = input.payload[k];
  const out = { channel: input.channel, type: input.type, template: input.template, identity: input.identity ?? "", payload: p };
  if (input.language !== undefined) out.language = input.language; // top level, next to channel/template
  return out;
};
const errMsg = (f) => {
  try { f(); return null; } catch (e) { return e.message; }
};

// ── send(): valid inputs → payload JSON, wire body and plaintext ──
const SEND_INPUTS = {
  email_otp: { channel: "Email", type: "Verification", template: "Otp", identity: "noreply@example.com", payload: { to: "user@example.com", otp: "012345" } },
  email_custom_unicode: { channel: "Email", type: "Transactional", template: "Custom", identity: "noreply@example.com",
    payload: { to: "user@example.com", subject: "Héllo \"quoted\" \\ back/slash", body: "Line 1\nLine 2\tTab <b>&amp;</b> € 😀 \u0001 ✓" } },
  email_panel_template: { channel: "Email", type: "Transactional", template: "welcome", identity: "noreply@example.com",
    payload: { to: "user@example.com", data: { name: "Ada", plan: "Pro" } } },
  whatsapp_otp: { channel: "WhatsApp", type: "Verification", template: "Otp", identity: "919578456444", payload: { to: "+91 98765 43210", otp: "A1B2C3" } },
  whatsapp_custom: { channel: "WhatsApp", type: "Transactional", template: "Custom", identity: "919578456444",
    payload: { to: "+91 98765 43210", subject: "Order shipped", body: "Your order arrives Friday." } },
  push_token_full: { channel: "Push", type: "Notification", template: "Notification", identity: "my-firebase-project",
    payload: { to: "fcm-token-123", body: "You have mail", title: "Inbox", data: { order: "42", kind: "mail" },
      image: "https://example.com/i.png", link: "https://example.com/inbox", device_key: "DEVICEKEYBASE64=" } },
  push_external_user: { channel: "Push", type: "Notification", template: "Notification", identity: "my-firebase-project",
    payload: { body: "Hi", external_user_id: "user-77" } },
  sms_otp: { channel: "SMS", type: "Verification", template: "Otp", identity: "", payload: { to: "+14155550100", otp: "482913" } },
  sms_custom_india: { channel: "SMS", type: "Transactional", template: " custom ", identity: "",
    payload: { to: "+91 98765-43210", body: "Your code is ready", gateway: "msg91-main", sender: "CATZIN", dlt_template_id: "1207161234567890123" } },
  sms_panel_template: { channel: "SMS", type: "Promotional", template: "sale_alert", identity: "ignored",
    payload: { to: "+447700900123", data: { pct: "20" }, otp: "   ", body: "" } },
  voice_otp: { channel: "Voice", type: "Verification", template: "otp", identity: "",
    payload: { to: "+1 (415) 555-0100", otp: " 482913 ", data: { language: "en-US", voice: "female", repeat: " 2 " } } },
  voice_custom_provider: { channel: "voice", type: "Notification", template: "Custom", identity: "",
    payload: { to: "+919876543210", body: "  Your table is ready.  ", provider: " Exotel India " } },
  voice_panel_template: { channel: "Voice", type: "Transactional", template: "appointment", identity: "",
    payload: { to: "+14155550100", data: { time: "3 pm" } } },
  // 1.5.0: top-level language (BCP-47 tags reduced to the primary subtag).
  email_otp_language: { channel: "Email", type: "Verification", template: "Otp", identity: "noreply@example.com", language: "de-DE",
    payload: { to: "user@example.com", otp: "012345" } },
  whatsapp_otp_language: { channel: "WhatsApp", type: "Verification", template: "Otp", identity: "919578456444", language: "ar",
    payload: { to: "+91 98765 43210", otp: "A1B2C3" } },
  sms_otp_language: { channel: "SMS", type: "Verification", template: "Otp", identity: "", language: " HI_in ",
    payload: { to: "+14155550100", otp: "482913" } },
  voice_otp_language_data_override: { channel: "Voice", type: "Verification", template: "otp", identity: "", language: "ja",
    payload: { to: "+14155550100", otp: "482913", data: { language: "en-US" } } },
  email_custom_language: { channel: "Email", type: "Transactional", template: "Custom", identity: "noreply@example.com", language: "en",
    payload: { to: "user@example.com", subject: "s", body: "b" } },
};

const sends = [];
for (const [name, raw] of Object.entries(SEND_INPUTS)) {
  const input = canon(raw);
  mockFetch(200, { success: true, message: "Queued", data: { message_id: "m-" + name, segments: 1, encoding: "gsm7" } });
  const res = await ts.catzconnect.send(input, env);
  const s = seen[0];
  sends.push({
    name,
    input,
    payload_json: JSON.stringify(ts.buildSendPayload(input)),
    url: s.url,
    authorization: s.headers.Authorization,
    content_type: s.headers["Content-Type"],
    nonce: s.body.nonce,
    ciphertext: s.body.ciphertext,
    plaintext: s.plaintext,
    response: res,
  });
}

// ── send(): refused by the server ──
mockFetch(403, { success: false, message: "Your plan does not include SMS", code: "plan_required" });
let sendError;
try {
  await ts.catzconnect.send(canon(SEND_INPUTS.sms_otp), env);
} catch (e) {
  sendError = { message: e.message, status: e.status, code: e.code, body: e.body };
}

// ── validation errors (messages must match word for word) ──
const INVALID = [
  { channel: "Email", type: "Verification", template: "Otp", identity: "", payload: { to: "a@b.co", otp: "123456" } },
  { channel: "Email", type: "Verification", template: "Otp", identity: "x", payload: { otp: "123456" } },
  { channel: "Email", type: "Verification", template: "Otp", identity: "x", payload: { to: "a@b.co" } },
  { channel: "Email", type: "Verification", template: "Otp", identity: "x", payload: { to: "not-an-email", otp: "123456" } },
  { channel: "Email", type: "Verification", template: "Otp", identity: "x", payload: { to: "a@b.co", otp: "12a456" } },
  { channel: "Email", type: "Verification", template: "Otp", identity: "x", payload: { to: "a@b.co", otp: "12345" } },
  { channel: "Email", type: "Verification", template: "Otp", identity: "x", payload: { to: "a@b.co", otp: "" } },
  { channel: "Email", type: "Transactional", template: "Custom", identity: "x", payload: { to: "a@b.co", body: "b" } },
  { channel: "Email", type: "Transactional", template: "Custom", identity: "x", payload: { to: "a@b.co", subject: "s" } },
  { channel: "Email", type: "Notification", template: "Notification", identity: "x", payload: { to: "a@b.co" } },
  { channel: "Email", type: "Verification", template: "Custom", identity: "x", payload: { to: "a@b.co" } },
  { channel: "Email", type: "Transactional", template: "welcome", identity: "x", payload: {} },
  { channel: "WhatsApp", type: "Verification", template: "Otp", identity: "x", payload: { to: "user@example.com", otp: "1" } },
  { channel: "WhatsApp", type: "Verification", template: "Otp", identity: "x", payload: { to: "12345", otp: "1" } },
  { channel: "WhatsApp", type: "Verification", template: "Otp", identity: "x", payload: { to: "+1 415 555 0100", otp: "1234567890123456" } },
  { channel: "WhatsApp", type: "Verification", template: "Otp", identity: "x", payload: { to: "+1 415 555 0100", otp: "12-34" } },
  { channel: "WhatsApp", type: "Transactional", template: "Custom", identity: "x", payload: { to: "+1 415 555 0100", body: "" } },
  { channel: "WhatsApp", type: "Transactional", template: "Custom", identity: "x", payload: { to: "+1 415 555 0100", subject: "s", body: "x".repeat(4091) } },
  { channel: "WhatsApp", type: "Transactional", template: "Custom", identity: "x", payload: { to: "abc", body: "x" } },
  { channel: "Push", type: "Notification", template: "Notification", identity: "", payload: { to: "t", body: "b" } },
  { channel: "Push", type: "Notification", template: "Notification", identity: "p", payload: { to: "t", body: "b", external_user_id: "u" } },
  { channel: "Push", type: "Notification", template: "Notification", identity: "p", payload: { body: "b" } },
  { channel: "Push", type: "Notification", template: "Notification", identity: "p", payload: { to: "a@b.co", body: "b" } },
  { channel: "Push", type: "Notification", template: "Notification", identity: "p", payload: { body: "b", external_user_id: "u".repeat(129) } },
  { channel: "Push", type: "Notification", template: "Notification", identity: "p", payload: { body: "b", device_key: "k", external_user_id: "u" } },
  { channel: "Push", type: "Notification", template: "Notification", identity: "p", payload: { to: "t" } },
  { channel: "Push", type: "Notification", template: "Notification", identity: "p", payload: { to: "t", body: "b", image: "http://x/i.png" } },
  { channel: "Push", type: "Notification", template: "Notification", identity: "p", payload: { to: "t", body: "b", link: "ftp://x" } },
  { channel: "SMS", type: "Verification", template: "Otp", payload: {} },
  { channel: "SMS", type: "Verification", template: "Otp", payload: { to: "0044 7700 900123", otp: "1" } },
  { channel: "SMS", type: "Notification", template: "Otp", payload: { to: "+447700900123", otp: "1" } },
  { channel: "SMS", type: "Transactional", template: "Custom", payload: { to: "+447700900123", body: "b", sender: "CATZ" } },
  { channel: "SMS", type: "Transactional", template: "Custom", payload: { to: "+447700900123", body: "b", gateway: "g", sender: "X" } },
  { channel: "SMS", type: "Transactional", template: "Custom", payload: { to: "+447700900123", body: "b", dlt_template_id: "12ab" } },
  { channel: "SMS", type: "Transactional", template: "  ", payload: { to: "+447700900123" } },
  { channel: "SMS", type: "Transactional", template: "otp", payload: { to: "+447700900123", otp: "1" } },
  { channel: "SMS", type: "Verification", template: "OTP", payload: { to: "+447700900123", otp: " " } },
  { channel: "SMS", type: "Verification", template: "Otp", payload: { to: "+447700900123", otp: "12345678901234567" } },
  { channel: "SMS", type: "Verification", template: "Custom", payload: { to: "+447700900123", body: "b" } },
  { channel: "SMS", type: "Transactional", template: "Custom", payload: { to: "+447700900123", body: "  " } },
  { channel: "SMS", type: "Transactional", template: "Custom", payload: { to: "+447700900123", body: "bell \u0007" } },
  { channel: "SMS", type: "Transactional", template: "Custom", payload: { to: "+447700900123", body: "x".repeat(1531) } },
  { channel: "SMS", type: "Transactional", template: "Custom", payload: { to: "+447700900123", body: "€".repeat(766) } },
  { channel: "SMS", type: "Promotional", template: "Custom", payload: { to: "+447700900123", body: "ü".repeat(10) + "😀".repeat(331) } },
  { channel: "SMS", type: "Transactional", template: "Custom", payload: { to: "+919876543210", body: "hello" } },
  { channel: "Voice", type: "Verification", template: "Otp", payload: { otp: "1" } },
  { channel: "Voice", type: "Verification", template: "Otp", payload: { to: "12345", otp: "1" } },
  { channel: "Voice", type: "Verification", template: "Otp", payload: { to: "+14155550100", otp: "1", provider: "  " } },
  { channel: "Voice", type: "Verification", template: "Otp", payload: { to: "+14155550100", otp: "1", data: { repeat: "4" } } },
  { channel: "Voice", type: "Verification", template: "Otp", payload: { to: "+14155550100", otp: "1", data: { repeat: "1.5" } } },
  { channel: "Voice", type: "Verification", template: "Otp", payload: { to: "+14155550100", otp: "1", data: { language: "english" } } },
  { channel: "Voice", type: "Verification", template: "Otp", payload: { to: "+14155550100", otp: "1", data: { voice: " female" } } },
  { channel: "Voice", type: "Verification", template: "", payload: { to: "+14155550100" } },
  { channel: "Voice", type: "Verification", template: "Otp", payload: { to: "+14155550100" } },
  { channel: "Voice", type: "Verification", template: "Otp", payload: { to: "+14155550100", otp: "12 34" } },
  { channel: "Voice", type: "Notification", template: "Custom", payload: { to: "+14155550100", body: " " } },
  { channel: "Voice", type: "Notification", template: "Custom", payload: { to: "+14155550100", body: "a\u0000b" } },
  { channel: "Voice", type: "Notification", template: "Custom", payload: { to: "+14155550100", body: "é".repeat(1001) } },
  // 1.5.0: language
  { channel: "Email", type: "Verification", template: "Otp", identity: "x", language: "fr", payload: { to: "a@b.co", otp: "123456" } },
  { channel: "SMS", type: "Verification", template: "Otp", language: "fr-FR", payload: { to: "+447700900123", otp: "1" } },
  { channel: "Voice", type: "Verification", template: "Otp", language: "", payload: { to: "+14155550100", otp: "1" } },
  { channel: "Email", type: "Verification", template: "Otp", identity: "x", language: "de--DE", payload: { to: "a@b.co", otp: "123456" } },
  { channel: "Email", type: "Verification", template: "Otp", identity: "x", language: "english", payload: { to: "a@b.co", otp: "123456" } },
  { channel: "Email", type: "Verification", template: "Otp", identity: "", language: "xx", payload: { to: "a@b.co", otp: "123456" } },
  { channel: "WhatsApp", type: "Verification", template: "Otp", identity: "x", language: "hi-IN", payload: { to: "+1 415 555 0100", otp: "1" } },
].map(canon);
// verifyPayload is not exported by the TS index; drive send() and read the message.
const validation = INVALID.map((input) => ({ input, error: null }));
for (const v of validation) {
  mockFetch(200, { success: true });
  try {
    await ts.catzconnect.send(v.input, env);
    v.error = null;
  } catch (e) {
    v.error = e.message;
  }
}

// ── SMS and Voice helpers ──
const SMS_TEXTS = ["", "Hello", "x".repeat(160), "x".repeat(161), "x".repeat(306), "x".repeat(307), "€".repeat(80), "€".repeat(81),
  "[curly]{}^~|\\", "Ünïcödé", "😀", "a😀b", "Ç".repeat(70), "ç".repeat(70), "ç".repeat(71), "😀".repeat(35), "😀".repeat(36),
  "x".repeat(152) + "€", "x".repeat(153) + "€", "\n\r\f @£$¥", "Ελληνικά ΔΦΓΛΩΠΨΣΘΞ"];
const sms = {
  analyse: SMS_TEXTS.map((t) => ({ text: t, result: ts.analyseSms(t) })),
  e164: ["+919876543210", " +91 98765-43210 ", "+1 (415) 555.0100", "919876543210", "+0123456789", "+1234567", "+12345678",
    "+123456789012345", "+1234567890123456", "", "+91 98765 4321a"].map((s) => ({ input: s, result: ts.normaliseE164(s) })),
  sender: ["CATZ", "CATZIN", "C", "CATZCONNECT", "CATZCONNECTX", "12345", "+14155550100", "+1 415 555 0100", " CATZ", "CATZ ",
    "CA TZ", "CATZ-IN", "Ab"].map((s) => ({ input: s, result: ts.isValidSmsSender(s) })),
  dlt: ["123456", "12345", "1".repeat(30), "1".repeat(31), "12a456", ""].map((s) => ({ input: s, result: ts.isValidDltId(s) })),
};
const voice = {
  language: ["en-US", "hi-IN", "es-419", "fr", "zh-Hant-TW", "english", "e", "en_US", "en-", "en-US-x-a"].map((s) => ({ input: s, result: ts.isValidVoiceLanguage(s) })),
  name: ["female", "male", "Polly.Joanna", "en-US-Wavenet-F", "a:b", " female", "female ", "x".repeat(64), "x".repeat(65), "bad!", ""].map((s) => ({ input: s, result: ts.isValidVoiceName(s) })),
  text: [" hello ", "", "  ", "a\u0007b", "tab\tok\nnew", "é".repeat(1000), "é".repeat(1001), "😀".repeat(1000)].map((s) => {
    try { return { input: s, result: ts.validateVoiceText(s), error: null }; } catch (e) { return { input: s, result: null, error: e.message }; }
  }),
  repeat: ["1", " 3 ", "0", "4", "2.0", "abc", "", "03"].map((s) => {
    try { return { input: s, result: ts.parseVoiceRepeat(s), error: null }; } catch (e) { return { input: s, result: null, error: e.message }; }
  }),
};

// ── calls ──
const CREATE_INPUTS = [
  { mode: "video", from: "alice", to: ["bob"] },
  { mode: "audio", from: "alice", to: ["bob", "carol"], engine: " catz ", ring: false, metadata: { order: "A-1042", n: 7, nested: { ok: true } }, maxParticipants: 4 },
];
const CREATE_INVALID = [
  { mode: "video", from: "", to: ["bob"] },
  { mode: "video", from: "a".repeat(129), to: ["bob"] },
  { mode: "video", from: "al\u0001ice", to: ["bob"] },
  { mode: "video", from: "alice", to: [] },
  { mode: "video", from: "alice", to: Array.from({ length: 50 }, (_, i) => "u" + i) },
  { mode: "video", from: "alice", to: ["alice"] },
  { mode: "video", from: "alice", to: ["bob", "bob"] },
  { mode: "video", from: "alice", to: [" "] },
  { mode: "video", from: "alice", to: ["bob"], engine: "  " },
  { mode: "video", from: "alice", to: ["bob"], metadata: { big: "x".repeat(4090) } },
  { mode: "video", from: "alice", to: ["bob"], maxParticipants: 1 },
  { mode: "video", from: "alice", to: ["bob"], maxParticipants: 51 },
  { mode: "video", from: "alice", to: ["bob", "carol"], maxParticipants: 2 },
];
const calls = {
  create_payloads: CREATE_INPUTS.map((input) => ({ input, payload_json: JSON.stringify(ts.buildCreateCallPayload(input)) })),
  create_errors: CREATE_INVALID.map((input) => ({ input, error: errMsg(() => ts.buildCreateCallPayload(input)) })),
  token_payloads: [["alice", undefined], ["alice", 600], ["alice", 59], ["alice", 86401], ["", 600]].map(([u, t]) => {
    try { return { user_id: u, ttl: t ?? null, payload_json: JSON.stringify(ts.buildCallTokenPayload(u, t)), error: null }; }
    catch (e) { return { user_id: u, ttl: t ?? null, payload_json: null, error: e.message }; }
  }),
};

const CALL = { id: "c1", engine: "catz", provider: null, mode: "video", status: "ringing", room: "c1",
  participants: [{ user_id: "alice", role: "caller", state: "joined", joined_at: "2026-10-18T00:00:01Z", seconds: 0, connection: "direct" },
    { user_id: "bob", role: "callee", state: "ringing" }],
  created_at: "2026-10-18T00:00:00Z", metadata: { order: "A-1042" } };

mockFetch(200, { success: true, call: CALL });
const created = await ts.catzconnect.calls.create(CREATE_INPUTS[1], env);
calls.create_request = { url: seen[0].url, authorization: seen[0].headers.Authorization, accept: seen[0].headers.Accept,
  nonce: seen[0].body.nonce, ciphertext: seen[0].body.ciphertext, plaintext: seen[0].plaintext, response: { success: true, call: CALL }, result: created };

// A response whose data is sealed (the SDKs open it with the request key).
const sealedData = serverSeal({ token: "ct1.a.b", expires_at: 99, ws_url: "wss://x/rtc/v1/ws" }, Uint8Array.from({ length: 12 }, (_, i) => 100 + i));
mockFetch(200, { success: true, message: "ok", data: sealedData });
const tok = await ts.catzconnect.calls.token("alice", 600, env);
calls.token_request = { url: seen[0].url, plaintext: seen[0].plaintext, response: { success: true, message: "ok", data: sealedData }, result: tok };

const sealedTop = serverSeal({ success: true, data: { call: CALL } }, Uint8Array.from({ length: 12 }, (_, i) => 200 + i));
mockFetch(200, sealedTop);
const got = await ts.catzconnect.calls.get(" c1 ", env);
calls.get_request = { url: seen[0].url, plaintext: seen[0].plaintext, response: sealedTop, result_id: got.id, result_status: got.status };

mockFetch(200, { success: true, message: "Call ended" });
calls.end_request = { result: await ts.catzconnect.calls.end("c1", "  done ", env), plaintext: seen[0].plaintext };

const callErrors = [];
for (const [status, body] of [[402, JSON.stringify({ success: false, message: "Your plan does not include calls", code: "plan_required" })],
  [200, JSON.stringify({ success: false, message: "Call not found", code: "not_found" })],
  [500, "upstream exploded"],
  [200, "<html>oops</html>"]]) {
  mockFetch(status, body);
  try { await ts.catzconnect.calls.get("c1", env); callErrors.push({ status, body, error: null }); }
  catch (e) { callErrors.push({ status, body, error: { name: e.name, message: e.message, status: e.status, code: e.code ?? null, body: e.body } }); }
}
calls.errors = callErrors;

// ── webhooks and user_hash ──
const secret = "whsec_test_secret";
const body = '{"event":"sms.delivered","data":{"message_id":"m1","note":"ünï"}}';
const t = 1760745600;
const sig = (tt, b = body, s = secret) => createHmac("sha256", s).update(`${tt}.`).update(Buffer.from(b, "utf8")).digest("hex");
const good = sig(t);
const WEBHOOK = [
  { header: `t=${t},v1=${good}`, now: t },
  { header: `t=${t},v1=${good.toUpperCase()}`, now: t },
  { header: ` t = ${t} , v1 = ${good} `, now: t },
  { header: `t=${t},v1=${"0".repeat(64)},v1=${good}`, now: t },
  { header: `t=${t},v1=${good}`, now: t + 301 },
  { header: `t=${t},v1=${good}`, now: t - 300 },
  { header: `t=${t},v1=${good}`, now: t + 10000, tolerance: 0 },
  { header: `t=${t + 1},v1=${good}`, now: t },
  { header: `v1=${good}`, now: t },
  { header: `t=${t}`, now: t },
  { header: `t=abc,v1=${good}`, now: t },
  { header: `t=${t},v1=${good.slice(0, 63)}`, now: t },
  { header: "", now: t },
  { header: `t=${t},v1=${good}`, now: t, secret: "" },
  { header: `t=${t},v1=${good}`, now: t, secret: "whsec_other" },
  { header: `t=${t},v1=${good}`, now: t, body: body + " " },
  { header: `t=${t},v1=${sig(t, "", secret)}`, now: t, body: "" },
  { header: `t=${t},v1=${sig(t, body, "k".repeat(100))}`, now: t, secret: "k".repeat(100) },
].map((c) => ({
  body: c.body ?? body, secret: c.secret ?? secret, header: c.header, now: c.now, tolerance: c.tolerance ?? 300,
  result: ts.verifyWebhookSignature(c.body ?? body, c.header, c.secret ?? secret, c.tolerance ?? 300, c.now),
}));
const USER_HASH = [["user-1", "pis_secret"], ["", "pis_secret"], ["ünïcödé 😀", "pis_ü"], ["u", "x".repeat(200)]]
  .map(([u, s]) => ({ external_user_id: u, secret: s, hash: ts.computeUserHash(u, s) }));
const userHashError = errMsg(() => ts.computeUserHash("u", ""));

// ── push: sealed to a fixed device key ──
const device = sodium.crypto_box_seed_keypair(new Uint8Array(32).fill(5));
const deviceKeys = { publicKey: b64(device.publicKey), privateKey: b64(device.privateKey) };
const pushContent = { title: "Inbox", body: "You have mail 📬", data: { order: "42" }, image: "https://example.com/i.png", link: null };
const sealed = b64(sodium.crypto_box_seal(sodium.from_string(JSON.stringify(pushContent)), device.publicKey));
const pushData = { catz_v: "1", catz_sealed: sealed, catz_id: "p-1" };
const opened = await ts.openPushPayload(pushData, deviceKeys);
const minimal = b64(sodium.crypto_box_seal(sodium.from_string(JSON.stringify({ body: "Hi" })), device.publicKey));
const openedMinimal = await ts.openPushPayload({ catz_v: "1", catz_sealed: minimal }, deviceKeys);
const otherDevice = sodium.crypto_box_seed_keypair(new Uint8Array(32).fill(6));
const push = {
  device_keys: deviceKeys,
  other_device_keys: { publicKey: b64(otherDevice.publicKey), privateKey: b64(otherDevice.privateKey) },
  cases: [
    { data: pushData, opened },
    { data: { catz_v: "1", catz_sealed: minimal }, opened: openedMinimal },
  ],
  is_sealed: [
    { data: pushData, result: ts.isSealedPush(pushData) },
    { data: { catz_v: "2", catz_sealed: sealed }, result: ts.isSealedPush({ catz_v: "2", catz_sealed: sealed }) },
    { data: { catz_sealed: sealed }, result: ts.isSealedPush({ catz_sealed: sealed }) },
    { data: { catz_v: "1" }, result: ts.isSealedPush({ catz_v: "1" }) },
    { data: {}, result: ts.isSealedPush({}) },
  ],
};

const out = {
  generated_by: "sdk/dart/catzconnect/tool/gen_vectors.mjs with the TypeScript SDK 1.5.0",
  keys: { client_private: b64(clientPriv), client_public: b64(clientPub), server_private: b64(serverPriv), server_public: b64(serverPub),
    derived_key: b64(KEY), api_key: env.api_key },
  fixed_nonce: b64(FIXED_NONCE),
  fixed_ts: FIXED_TS,
  base_url_env: process.env.CATZCONNECT_BASE_URL,
  sends,
  send_error: sendError,
  validation,
  sms,
  voice,
  calls,
  webhook: WEBHOOK,
  user_hash: USER_HASH,
  user_hash_error: userHashError,
  push,
};
const file = join(here, "../test/fixtures/vectors.json");
mkdirSync(dirname(file), { recursive: true });
writeFileSync(file, JSON.stringify(out, null, 2) + "\n");
console.log(`wrote ${file}: ${sends.length} sends, ${validation.length} validation cases, ${WEBHOOK.length} webhook cases`);
