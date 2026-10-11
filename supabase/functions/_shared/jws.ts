// Verifies App Store signed data (StoreKit 2 transactions and App Store
// Server Notifications V2), which arrive as JWS with an x5c certificate chain.
//
// A payload is trusted only if all of the following hold:
//   1. The chain is leaf -> intermediate -> root, each signed by the next.
//   2. The root is Apple Root CA - G3, pinned here by SHA-256 fingerprint.
//   3. Every certificate is inside its validity period.
//   4. When the root is Apple's, the leaf and intermediate carry the
//      extensions Apple issues App Store signing certificates with.
//   5. The JWS signature verifies against the leaf's public key (ES256).
//
// Certificates are parsed here and checked with WebCrypto. The runtime's own
// X509Certificate class is deliberately not used: Supabase's Edge runtime does
// not implement its `verify`, so code that passes under Node fails there.
//
// This module has no Deno- or Supabase-specific imports so that it can be
// unit tested with Node (see supabase/tests/jws.test.js).

import { Buffer } from "node:buffer";

/** SHA-256 fingerprint of Apple Root CA - G3 (valid until 30 April 2039). */
export const APPLE_ROOT_CA_G3_SHA256 =
  "63:34:3A:BF:B8:9A:6A:03:EB:B5:7E:9B:3F:5F:A7:BE:7C:4F:5C:75:6F:30:17:B3:A8:C4:88:C3:65:3E:91:79";

export class JwsVerificationError extends Error {
  readonly reason: string;

  constructor(reason: string) {
    super(`jws_verification_failed:${reason}`);
    this.reason = reason;
  }
}

function fromBase64Url(value: string): Buffer {
  return Buffer.from(value.replace(/-/g, "+").replace(/_/g, "/"), "base64");
}

export interface VerifyOptions {
  /** Override the pinned root. For tests only. */
  rootFingerprint?: string;
  now?: Date;
}

function normaliseFingerprint(fingerprint: string): string {
  return fingerprint.replace(/[^0-9a-f]/gi, "").toLowerCase();
}

// --- A minimal X.509 reader --------------------------------------------------
// Only what the checks above need: the signed bytes, the signature and its
// algorithm, the validity period, the public key, and the extensions.

const OID = {
  ecdsaSha256: "2a8648ce3d040302",
  ecdsaSha384: "2a8648ce3d040303",
  ecdsaSha512: "2a8648ce3d040304",
  curveP256: "2a8648ce3d030107",
  curveP384: "2b81040022",
  basicConstraints: "551d13",
  // 1.2.840.113635.100.6.11.1: an App Store receipt signing certificate.
  appleReceiptSigning: "2a864886f76364060b01",
  // 1.2.840.113635.100.6.2.1: the Apple Worldwide Developer Relations CA.
  appleWwdrIntermediate: "2a864886f763640602" + "01",
};

const CURVES: Record<string, { name: "P-256" | "P-384"; size: number }> = {
  [OID.curveP256]: { name: "P-256", size: 32 },
  [OID.curveP384]: { name: "P-384", size: 48 },
};

const SIGNATURE_HASHES: Record<string, string> = {
  [OID.ecdsaSha256]: "SHA-256",
  [OID.ecdsaSha384]: "SHA-384",
  [OID.ecdsaSha512]: "SHA-512",
};

interface Tlv {
  tag: number;
  start: number;
  valueStart: number;
  end: number;
}

function readTlv(der: Buffer, offset: number, limit: number): Tlv {
  if (offset + 2 > limit) throw new JwsVerificationError("certificate");
  const tag = der[offset];
  let length = der[offset + 1];
  let valueStart = offset + 2;
  if (length & 0x80) {
    const count = length & 0x7f;
    if (count === 0 || count > 4 || valueStart + count > limit) throw new JwsVerificationError("certificate");
    length = 0;
    for (let index = 0; index < count; index += 1) length = length * 256 + der[valueStart + index];
    valueStart += count;
  }
  const end = valueStart + length;
  if (end > limit) throw new JwsVerificationError("certificate");
  return { tag, start: offset, valueStart, end };
}

function expectTag(tlv: Tlv, tag: number): Tlv {
  if (tlv.tag !== tag) throw new JwsVerificationError("certificate");
  return tlv;
}

function parseTime(der: Buffer, tlv: Tlv): Date {
  const text = der.subarray(tlv.valueStart, tlv.end).toString("latin1");
  let match: RegExpMatchArray | null;
  let year: number;
  if (tlv.tag === 0x17 && (match = text.match(/^(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})Z$/))) {
    year = Number(match[1]) + (Number(match[1]) >= 50 ? 1900 : 2000);
  } else if (tlv.tag === 0x18 && (match = text.match(/^(\d{4})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})Z$/))) {
    year = Number(match[1]);
  } else {
    throw new JwsVerificationError("certificate");
  }
  const [month, day, hour, minute, second] = match.slice(2).map(Number);
  return new Date(Date.UTC(year, month - 1, day, hour, minute, second));
}

interface Certificate {
  der: Buffer;
  /** The bytes the issuer signed. */
  signed: Buffer;
  signatureHash: string;
  /** DER-encoded ECDSA signature. */
  signature: Buffer;
  notBefore: Date;
  notAfter: Date;
  publicKey: Buffer;
  curve: { name: "P-256" | "P-384"; size: number };
  isAuthority: boolean;
  extensions: Set<string>;
}

function parseCertificate(der: Buffer): Certificate {
  const whole = expectTag(readTlv(der, 0, der.length), 0x30);
  if (whole.end !== der.length) throw new JwsVerificationError("certificate");

  const tbs = expectTag(readTlv(der, whole.valueStart, whole.end), 0x30);
  const algorithm = expectTag(readTlv(der, tbs.end, whole.end), 0x30);
  const algorithmOid = expectTag(readTlv(der, algorithm.valueStart, algorithm.end), 0x06);
  const signatureHash = SIGNATURE_HASHES[der.subarray(algorithmOid.valueStart, algorithmOid.end).toString("hex")];
  const signatureBits = expectTag(readTlv(der, algorithm.end, whole.end), 0x03);
  if (!signatureHash || der[signatureBits.valueStart] !== 0) throw new JwsVerificationError("certificate");

  let field = readTlv(der, tbs.valueStart, tbs.end);
  if (field.tag === 0xa0) field = readTlv(der, field.end, tbs.end); // version
  expectTag(field, 0x02); // serial number
  field = expectTag(readTlv(der, field.end, tbs.end), 0x30); // signature algorithm
  field = expectTag(readTlv(der, field.end, tbs.end), 0x30); // issuer
  const validity = expectTag(readTlv(der, field.end, tbs.end), 0x30);
  const notBefore = readTlv(der, validity.valueStart, validity.end);
  const notAfter = readTlv(der, notBefore.end, validity.end);
  field = expectTag(readTlv(der, validity.end, tbs.end), 0x30); // subject
  const keyInfo = expectTag(readTlv(der, field.end, tbs.end), 0x30);
  const keyAlgorithm = expectTag(readTlv(der, keyInfo.valueStart, keyInfo.end), 0x30);
  const keyType = expectTag(readTlv(der, keyAlgorithm.valueStart, keyAlgorithm.end), 0x06);
  const curveOid = expectTag(readTlv(der, keyType.end, keyAlgorithm.end), 0x06);
  const curve = CURVES[der.subarray(curveOid.valueStart, curveOid.end).toString("hex")];
  if (!curve) throw new JwsVerificationError("certificate");

  const extensions = new Set<string>();
  let isAuthority = false;
  let offset = keyInfo.end;
  while (offset < tbs.end) {
    const optional = readTlv(der, offset, tbs.end);
    offset = optional.end;
    if (optional.tag !== 0xa3) continue;
    const list = expectTag(readTlv(der, optional.valueStart, optional.end), 0x30);
    let position = list.valueStart;
    while (position < list.end) {
      const extension = expectTag(readTlv(der, position, list.end), 0x30);
      position = extension.end;
      const oid = expectTag(readTlv(der, extension.valueStart, extension.end), 0x06);
      const id = der.subarray(oid.valueStart, oid.end).toString("hex");
      extensions.add(id);
      if (id !== OID.basicConstraints) continue;
      let value = readTlv(der, oid.end, extension.end);
      if (value.tag === 0x01) value = readTlv(der, value.end, extension.end); // critical flag
      expectTag(value, 0x04);
      const constraints = expectTag(readTlv(der, value.valueStart, value.end), 0x30);
      if (constraints.end > constraints.valueStart) {
        const first = readTlv(der, constraints.valueStart, constraints.end);
        isAuthority = first.tag === 0x01 && der[first.valueStart] !== 0;
      }
    }
  }

  return {
    der,
    signed: der.subarray(tbs.start, tbs.end),
    signatureHash,
    signature: der.subarray(signatureBits.valueStart + 1, signatureBits.end),
    notBefore: parseTime(der, notBefore),
    notAfter: parseTime(der, notAfter),
    publicKey: der.subarray(keyInfo.start, keyInfo.end),
    curve,
    isAuthority,
    extensions,
  };
}

/** Converts a DER ECDSA signature to the fixed-width (r || s) form WebCrypto takes. */
function derToRaw(signature: Buffer, size: number): Buffer | null {
  try {
    const sequence = expectTag(readTlv(signature, 0, signature.length), 0x30);
    const r = expectTag(readTlv(signature, sequence.valueStart, sequence.end), 0x02);
    const s = expectTag(readTlv(signature, r.end, sequence.end), 0x02);
    const raw = Buffer.alloc(size * 2);
    for (const [index, part] of [r, s].entries()) {
      let start = part.valueStart;
      while (start < part.end - 1 && signature[start] === 0) start += 1;
      const length = part.end - start;
      if (length > size) return null;
      signature.copy(raw, size * (index + 1) - length, start, part.end);
    }
    return raw;
  } catch {
    return null;
  }
}

async function verifyWith(signer: Certificate, hash: string, rawSignature: Buffer, data: Buffer): Promise<boolean> {
  try {
    const key = await crypto.subtle.importKey(
      "spki", signer.publicKey, { name: "ECDSA", namedCurve: signer.curve.name }, false, ["verify"],
    );
    return await crypto.subtle.verify({ name: "ECDSA", hash }, key, rawSignature, data);
  } catch {
    return false;
  }
}

async function isSignedBy(certificate: Certificate, issuer: Certificate): Promise<boolean> {
  const raw = derToRaw(certificate.signature, issuer.curve.size);
  return raw !== null && await verifyWith(issuer, certificate.signatureHash, raw, certificate.signed);
}

/** Exposed for tests only, so the reader can be checked against Apple's real certificates. */
export const internals = { parseCertificate, isSignedBy, OID };

/**
 * Verifies a compact JWS and returns its decoded payload.
 * Throws JwsVerificationError on any failure; never returns unverified data.
 */
export async function verifyAppleJws<T = Record<string, unknown>>(jws: string, options: VerifyOptions = {}): Promise<T> {
  const parts = typeof jws === "string" ? jws.split(".") : [];
  if (parts.length !== 3) throw new JwsVerificationError("format");
  const [headerPart, payloadPart, signaturePart] = parts;

  let header: { alg?: string; x5c?: string[] };
  try {
    header = JSON.parse(fromBase64Url(headerPart).toString("utf8"));
  } catch {
    throw new JwsVerificationError("header");
  }
  if (header.alg !== "ES256") throw new JwsVerificationError("algorithm");
  if (!Array.isArray(header.x5c) || header.x5c.length !== 3) throw new JwsVerificationError("chain_length");

  let chain: Certificate[];
  try {
    chain = header.x5c.map((der) => parseCertificate(Buffer.from(der, "base64")));
  } catch {
    throw new JwsVerificationError("certificate");
  }
  const [leaf, intermediate, root] = chain;

  const rootDigest = Buffer.from(await crypto.subtle.digest("SHA-256", root.der)).toString("hex");
  if (rootDigest !== normaliseFingerprint(options.rootFingerprint ?? APPLE_ROOT_CA_G3_SHA256)) {
    throw new JwsVerificationError("untrusted_root");
  }

  const now = options.now ?? new Date();
  for (const certificate of chain) {
    if (now < certificate.notBefore || now > certificate.notAfter) {
      throw new JwsVerificationError("certificate_expired");
    }
  }

  if (!await isSignedBy(root, root)) throw new JwsVerificationError("root_signature");
  if (!await isSignedBy(intermediate, root)) throw new JwsVerificationError("intermediate_signature");
  if (!await isSignedBy(leaf, intermediate)) throw new JwsVerificationError("leaf_signature");
  if (!intermediate.isAuthority) throw new JwsVerificationError("intermediate_not_ca");

  // Apple's root signs many things. Only certificates issued for App Store
  // signing may vouch for a transaction.
  if (options.rootFingerprint === undefined) {
    if (!intermediate.extensions.has(OID.appleWwdrIntermediate)) throw new JwsVerificationError("intermediate_purpose");
    if (!leaf.extensions.has(OID.appleReceiptSigning)) throw new JwsVerificationError("leaf_purpose");
  }

  const signature = fromBase64Url(signaturePart);
  if (signature.length !== 64 || leaf.curve.name !== "P-256") throw new JwsVerificationError("signature_length");
  const signedData = Buffer.from(`${headerPart}.${payloadPart}`, "utf8");
  if (!await verifyWith(leaf, "SHA-256", signature, signedData)) throw new JwsVerificationError("signature");

  try {
    return JSON.parse(fromBase64Url(payloadPart).toString("utf8")) as T;
  } catch {
    throw new JwsVerificationError("payload");
  }
}

// --- Mapping a verified transaction to a subscription row -------------------

export interface AppleTransaction {
  originalTransactionId: string;
  transactionId: string;
  productId: string;
  bundleId: string;
  environment: "Production" | "Sandbox" | "Xcode";
  appAccountToken?: string;
  expiresDate?: number;
  revocationDate?: number;
  type?: string;
}

export interface AppleRenewalInfo {
  autoRenewStatus?: number;
  gracePeriodExpiresDate?: number;
  isInBillingRetryPeriod?: boolean;
}

export type SubscriptionStatus = "active" | "grace" | "billing_retry" | "expired" | "revoked";

export interface SubscriptionRecord {
  originalTransactionId: string;
  userId: string | null;
  productId: string;
  status: SubscriptionStatus;
  expiresAt: string | null;
  autoRenew: boolean | null;
  environment: string;
  lastTransactionId: string;
}

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/**
 * Decides what a verified transaction (and, when available, its renewal info)
 * means for entitlement. Pure: the same inputs always give the same record.
 */
export function subscriptionRecord(
  transaction: AppleTransaction,
  renewal: AppleRenewalInfo | null,
  now: Date,
): SubscriptionRecord {
  let status: SubscriptionStatus;
  let expiresAt = transaction.expiresDate ?? null;

  if (transaction.revocationDate) {
    status = "revoked";
  } else if (renewal?.gracePeriodExpiresDate && renewal.gracePeriodExpiresDate > now.getTime()) {
    // Apple is retrying payment and asks that access continue meanwhile.
    status = "grace";
    expiresAt = renewal.gracePeriodExpiresDate;
  } else if (expiresAt !== null && expiresAt <= now.getTime()) {
    status = renewal?.isInBillingRetryPeriod ? "billing_retry" : "expired";
  } else {
    status = "active";
  }

  return {
    originalTransactionId: transaction.originalTransactionId,
    userId: transaction.appAccountToken && UUID.test(transaction.appAccountToken)
      ? transaction.appAccountToken.toLowerCase()
      : null,
    productId: transaction.productId,
    status,
    expiresAt: expiresAt === null ? null : new Date(expiresAt).toISOString(),
    autoRenew: renewal?.autoRenewStatus === undefined ? null : renewal.autoRenewStatus === 1,
    environment: transaction.environment,
    lastTransactionId: transaction.transactionId,
  };
}

/** Rejects transactions for another app, another product, or a test environment in production. */
export function assertExpectedTransaction(
  transaction: AppleTransaction,
  expected: { bundleId: string; productIds: string[]; allowTestEnvironments: boolean },
): void {
  if (transaction.bundleId !== expected.bundleId) throw new JwsVerificationError("bundle_id");
  if (!expected.productIds.includes(transaction.productId)) throw new JwsVerificationError("product_id");
  if (!expected.allowTestEnvironments && transaction.environment !== "Production") {
    throw new JwsVerificationError("environment");
  }
}
