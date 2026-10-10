// Verifies App Store signed data (StoreKit 2 transactions and App Store
// Server Notifications V2), which arrive as JWS with an x5c certificate chain.
//
// A payload is trusted only if all of the following hold:
//   1. The chain is leaf -> intermediate -> root, each signed by the next.
//   2. The root is Apple Root CA - G3, pinned here by SHA-256 fingerprint.
//   3. Every certificate is inside its validity period.
//   4. The JWS signature verifies against the leaf's public key (ES256).
//
// This module has no Deno- or Supabase-specific imports so that it can be
// unit tested with Node (see supabase/tests/jws.test.js).

import { createPublicKey, verify, X509Certificate } from "node:crypto";
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

/** Converts a raw (r || s) ECDSA signature, as used by JWS, to DER. */
function joseToDer(signature: Buffer): Buffer {
  if (signature.length !== 64) throw new JwsVerificationError("signature_length");
  const encodeInteger = (bytes: Buffer): Buffer => {
    let start = 0;
    while (start < bytes.length - 1 && bytes[start] === 0) start += 1;
    let value = bytes.subarray(start);
    if (value[0] & 0x80) value = Buffer.concat([Buffer.from([0]), value]);
    return Buffer.concat([Buffer.from([0x02, value.length]), value]);
  };
  const r = encodeInteger(signature.subarray(0, 32));
  const s = encodeInteger(signature.subarray(32));
  return Buffer.concat([Buffer.from([0x30, r.length + s.length]), r, s]);
}

export interface VerifyOptions {
  /** Override the pinned root. For tests only. */
  rootFingerprint?: string;
  now?: Date;
}

/**
 * Verifies a compact JWS and returns its decoded payload.
 * Throws JwsVerificationError on any failure; never returns unverified data.
 */
export function verifyAppleJws<T = Record<string, unknown>>(jws: string, options: VerifyOptions = {}): T {
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

  let chain: X509Certificate[];
  try {
    chain = header.x5c.map((der) => new X509Certificate(Buffer.from(der, "base64")));
  } catch {
    throw new JwsVerificationError("certificate");
  }
  const [leaf, intermediate, root] = chain;

  const pinned = options.rootFingerprint ?? APPLE_ROOT_CA_G3_SHA256;
  if (root.fingerprint256 !== pinned) throw new JwsVerificationError("untrusted_root");

  const now = options.now ?? new Date();
  for (const certificate of chain) {
    if (now < new Date(certificate.validFrom) || now > new Date(certificate.validTo)) {
      throw new JwsVerificationError("certificate_expired");
    }
  }

  if (!root.verify(root.publicKey)) throw new JwsVerificationError("root_signature");
  if (!intermediate.verify(root.publicKey)) throw new JwsVerificationError("intermediate_signature");
  if (!leaf.verify(intermediate.publicKey)) throw new JwsVerificationError("leaf_signature");
  if (!intermediate.ca) throw new JwsVerificationError("intermediate_not_ca");

  const signedData = Buffer.from(`${headerPart}.${payloadPart}`, "utf8");
  const signature = joseToDer(fromBase64Url(signaturePart));
  const key = createPublicKey(leaf.publicKey.export({ type: "spki", format: "pem" }));
  if (!verify("sha256", signedData, key, signature)) throw new JwsVerificationError("signature");

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
