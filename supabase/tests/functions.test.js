// Unit tests for the pure logic inside the Edge Functions: Apple JWS
// verification, subscription state mapping, and notification wording.
// The TypeScript sources are imported directly (Node strips the types).
//
// A throwaway certificate chain is generated with openssl so that real
// signature and chain validation is exercised, with our test root standing in
// for Apple's. The functions themselves pin Apple Root CA - G3.

import { after, before, describe, test } from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { createPrivateKey, sign, X509Certificate } from 'node:crypto';
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

import {
  APPLE_ROOT_CA_G3_SHA256,
  assertExpectedTransaction,
  JwsVerificationError,
  subscriptionRecord,
  internals,
  verifyAppleJws,
} from '../functions/_shared/jws.ts';
import { notificationText } from '../functions/_shared/messages.ts';

let dir;
let chain;

function openssl(...args) {
  execFileSync('openssl', args, { cwd: dir, stdio: 'pipe' });
}

function makeChain(prefix, { leafDays = '30' } = {}) {
  const ca = join(dir, `${prefix}-ca.cnf`);
  writeFileSync(ca, '[v3_ca]\nbasicConstraints=critical,CA:TRUE\nkeyUsage=critical,keyCertSign\n[v3_leaf]\nbasicConstraints=CA:FALSE\n');
  for (const name of ['root', 'inter', 'leaf']) {
    openssl('ecparam', '-name', 'prime256v1', '-genkey', '-noout', '-out', `${prefix}-${name}.key`);
  }
  openssl('req', '-x509', '-new', '-key', `${prefix}-root.key`, '-subj', '/CN=Test Root', '-days', '30',
    '-config', ca, '-extensions', 'v3_ca', '-out', `${prefix}-root.pem`);
  openssl('req', '-new', '-key', `${prefix}-inter.key`, '-subj', '/CN=Test Intermediate', '-out', `${prefix}-inter.csr`);
  openssl('x509', '-req', '-in', `${prefix}-inter.csr`, '-CA', `${prefix}-root.pem`, '-CAkey', `${prefix}-root.key`,
    '-CAcreateserial', '-days', '30', '-extfile', ca, '-extensions', 'v3_ca', '-out', `${prefix}-inter.pem`);
  openssl('req', '-new', '-key', `${prefix}-leaf.key`, '-subj', '/CN=Test Leaf', '-out', `${prefix}-leaf.csr`);
  openssl('x509', '-req', '-in', `${prefix}-leaf.csr`, '-CA', `${prefix}-inter.pem`, '-CAkey', `${prefix}-inter.key`,
    '-CAcreateserial', '-days', leafDays, '-extfile', ca, '-extensions', 'v3_leaf', '-out', `${prefix}-leaf.pem`);

  const read = (name) => new X509Certificate(readFileSync(join(dir, `${prefix}-${name}.pem`)));
  const [leaf, inter, root] = [read('leaf'), read('inter'), read('root')];
  return {
    x5c: [leaf, inter, root].map((c) => c.raw.toString('base64')),
    leafKey: createPrivateKey(readFileSync(join(dir, `${prefix}-leaf.key`))),
    rootFingerprint: root.fingerprint256,
  };
}

const b64url = (value) => Buffer.from(value).toString('base64url');

function makeJws(payload, { x5c = chain.x5c, key = chain.leafKey, alg = 'ES256' } = {}) {
  const head = b64url(JSON.stringify({ alg, x5c }));
  const body = b64url(JSON.stringify(payload));
  const signature = sign('sha256', Buffer.from(`${head}.${body}`), { key, dsaEncoding: 'ieee-p1363' });
  return `${head}.${body}.${signature.toString('base64url')}`;
}

const isRejection = (reason) => (error) => {
  assert.ok(error instanceof JwsVerificationError, String(error));
  assert.equal(error.reason, reason);
  return true;
};
const rejects = (fn, reason) => assert.throws(fn, isRejection(reason));
const rejectsAsync = (fn, reason) => assert.rejects(async () => fn(), isRejection(reason));

const transaction = {
  originalTransactionId: '1000000000000001',
  transactionId: '1000000000000002',
  productId: 'com.example.couplenotes.premium.yearly',
  bundleId: 'com.example.couplenotes',
  environment: 'Production',
  appAccountToken: '7B1E7C0A-2F0B-4E0B-9E53-0A1B2C3D4E5F',
  expiresDate: Date.UTC(2030, 0, 1),
};

before(() => {
  dir = mkdtempSync(join(tmpdir(), 'jws-test-'));
  chain = makeChain('good');
});
after(() => rmSync(dir, { recursive: true, force: true }));

describe('Apple JWS verification', () => {
  test('the pinned root is Apple Root CA - G3', () => {
    assert.equal(
      APPLE_ROOT_CA_G3_SHA256,
      '63:34:3A:BF:B8:9A:6A:03:EB:B5:7E:9B:3F:5F:A7:BE:7C:4F:5C:75:6F:30:17:B3:A8:C4:88:C3:65:3E:91:79',
    );
  });

  test('a correctly signed transaction under the trusted root is accepted', async () => {
    const payload = await verifyAppleJws(makeJws(transaction), { rootFingerprint: chain.rootFingerprint });
    assert.deepEqual(payload, transaction);
  });

  test('a valid chain under any root other than the pinned one is rejected', async () => {
    // No override: the function must insist on Apple's root.
    await rejectsAsync(() => verifyAppleJws(makeJws(transaction)), 'untrusted_root');
  });

  test('a tampered payload is rejected', async () => {
    const [head, , signature] = makeJws(transaction).split('.');
    const forged = b64url(JSON.stringify({ ...transaction, expiresDate: Date.UTC(2099, 0, 1) }));
    await rejectsAsync(() => verifyAppleJws(`${head}.${forged}.${signature}`, { rootFingerprint: chain.rootFingerprint }), 'signature');
  });

  test('a signature made with a key that is not the leaf\'s is rejected', async () => {
    const other = makeChain('other');
    await rejectsAsync(
      () => verifyAppleJws(makeJws(transaction, { key: other.leafKey }), { rootFingerprint: chain.rootFingerprint }),
      'signature',
    );
  });

  test('a leaf that the presented intermediate did not sign is rejected', async () => {
    const other = makeChain('swap');
    const mixed = [other.x5c[0], chain.x5c[1], chain.x5c[2]];
    await rejectsAsync(
      () => verifyAppleJws(makeJws(transaction, { x5c: mixed, key: other.leafKey }), { rootFingerprint: chain.rootFingerprint }),
      'leaf_signature',
    );
  });

  test('an expired certificate is rejected', async () => {
    const later = new Date(Date.now() + 365 * 86_400_000);
    await rejectsAsync(() => verifyAppleJws(makeJws(transaction), { rootFingerprint: chain.rootFingerprint, now: later }), 'certificate_expired');
  });

  test('"alg: none", missing chains and garbage are rejected', async () => {
    const unsigned = `${b64url(JSON.stringify({ alg: 'none' }))}.${b64url(JSON.stringify(transaction))}.`;
    await rejectsAsync(() => verifyAppleJws(unsigned), 'algorithm');
    await rejectsAsync(() => verifyAppleJws(makeJws(transaction, { alg: 'HS256' })), 'algorithm');
    await rejectsAsync(() => verifyAppleJws(makeJws(transaction, { x5c: chain.x5c.slice(0, 2) })), 'chain_length');
    await rejectsAsync(() => verifyAppleJws(makeJws(transaction, { x5c: ['AAAA', 'AAAA', 'AAAA'] })), 'certificate');
    await rejectsAsync(() => verifyAppleJws('not-a-jws'), 'format');
    await rejectsAsync(() => verifyAppleJws(undefined), 'format');
    await rejectsAsync(() => verifyAppleJws('!!.!!.!!'), 'header');
  });

  test('Apple\'s real certificates are read and checked correctly', async () => {
    // The throwaway chains above are P-256 throughout. Apple's are P-384 and
    // signed with SHA-384, and carry the extensions the verifier insists on.
    const load = (name) => readFileSync(join(dirname(fileURLToPath(import.meta.url)), 'fixtures', name));
    const root = internals.parseCertificate(load('AppleRootCA-G3.cer'));
    const intermediate = internals.parseCertificate(load('AppleWWDRCAG6.cer'));
    assert.equal(root.curve.name, 'P-384');
    assert.equal(root.notAfter.toISOString(), '2039-04-30T18:19:06.000Z');
    assert.equal(await internals.isSignedBy(root, root), true);
    assert.equal(await internals.isSignedBy(intermediate, root), true);
    assert.equal(await internals.isSignedBy(root, intermediate), false);
    assert.equal(intermediate.isAuthority, true);
    assert.equal(intermediate.extensions.has(internals.OID.appleWwdrIntermediate), true);
    assert.equal(intermediate.extensions.has(internals.OID.appleReceiptSigning), false);
  });

  test('transactions for another app, product or environment are rejected', () => {
    const expected = { bundleId: 'com.example.couplenotes', productIds: [transaction.productId], allowTestEnvironments: false };
    assertExpectedTransaction(transaction, expected);
    rejects(() => assertExpectedTransaction({ ...transaction, bundleId: 'com.evil.app' }, expected), 'bundle_id');
    rejects(() => assertExpectedTransaction({ ...transaction, productId: 'something.else' }, expected), 'product_id');
    rejects(() => assertExpectedTransaction({ ...transaction, environment: 'Sandbox' }, expected), 'environment');
    rejects(() => assertExpectedTransaction({ ...transaction, environment: 'Xcode' }, expected), 'environment');
    assertExpectedTransaction({ ...transaction, environment: 'Sandbox' }, { ...expected, allowTestEnvironments: true });
  });
});

describe('subscription state', () => {
  const now = new Date(Date.UTC(2026, 9, 10));
  const future = Date.UTC(2026, 10, 10);
  const past = Date.UTC(2026, 8, 10);

  test('an unexpired subscription is active and bound to the purchasing account', () => {
    const record = subscriptionRecord({ ...transaction, expiresDate: future }, { autoRenewStatus: 1 }, now);
    assert.equal(record.status, 'active');
    assert.equal(record.userId, '7b1e7c0a-2f0b-4e0b-9e53-0a1b2c3d4e5f');
    assert.equal(record.autoRenew, true);
    assert.equal(record.expiresAt, new Date(future).toISOString());
  });

  test('refunds and revocations take precedence over everything', () => {
    const record = subscriptionRecord({ ...transaction, expiresDate: future, revocationDate: past }, { gracePeriodExpiresDate: future }, now);
    assert.equal(record.status, 'revoked');
  });

  test('a grace period keeps access until the grace period ends', () => {
    const grace = Date.UTC(2026, 9, 20);
    const record = subscriptionRecord({ ...transaction, expiresDate: past }, { gracePeriodExpiresDate: grace, isInBillingRetryPeriod: true }, now);
    assert.equal(record.status, 'grace');
    assert.equal(record.expiresAt, new Date(grace).toISOString());
  });

  test('expired, billing retry and a lapsed grace period grant nothing', () => {
    assert.equal(subscriptionRecord({ ...transaction, expiresDate: past }, null, now).status, 'expired');
    assert.equal(subscriptionRecord({ ...transaction, expiresDate: past }, { isInBillingRetryPeriod: true }, now).status, 'billing_retry');
    assert.equal(subscriptionRecord({ ...transaction, expiresDate: past }, { gracePeriodExpiresDate: past }, now).status, 'expired');
  });

  test('a missing or malformed account token yields no owner rather than a wrong one', () => {
    assert.equal(subscriptionRecord({ ...transaction, appAccountToken: undefined }, null, now).userId, null);
    assert.equal(subscriptionRecord({ ...transaction, appAccountToken: "'; drop table users; --" }, null, now).userId, null);
  });
});

describe('notification wording', () => {
  const base = { id: 1, user_id: 'u', tokens: [], sender_name: 'Sam', preview: null, date_title: null };

  test('a new note says who wrote, and not what, unless a preview was supplied', () => {
    const hidden = notificationText({ ...base, category: 'new_note', payload: { note_id: 'n1' } });
    assert.deepEqual(hidden, { title: 'Sam', body: 'Left you a note.', data: { note_id: 'n1' } });
    const shown = notificationText({ ...base, category: 'new_note', payload: { note_id: 'n1' }, preview: 'Dinner at eight?' });
    assert.equal(shown.body, 'Dinner at eight?');
  });

  test('a picture-only note with previews on has neutral wording', () => {
    const text = notificationText({ ...base, category: 'new_note', payload: {}, preview: '' });
    assert.equal(text.body, 'Sent you something to look at.');
  });

  test('together notifications never carry an answer, and open the right place', () => {
    const answered = notificationText({ ...base, category: 'together', payload: { event: 'answered', moment_id: 'm1' }, preview: 'should never be used' });
    assert.deepEqual(answered, { title: 'Sam', body: 'Answered today’s question. Your turn.', data: { together: '1' } });
    const ready = notificationText({ ...base, category: 'together', payload: { event: 'ready' } });
    assert.equal(ready.title, 'Your moment is ready');
    assert.equal(ready.body, 'You and Sam have both answered. Open it together.');
    assert.equal(notificationText({ ...base, category: 'together', payload: { event: 'new' } }).data.together, '1');
    assert.equal(notificationText({ ...base, category: 'together', payload: { event: 'something-else' } }), null);
  });

  test('an unnamed sender still reads naturally', () => {
    assert.equal(notificationText({ ...base, sender_name: '', category: 'new_note', payload: {} }).title, 'Your partner');
  });

  test('date reminders count down correctly', () => {
    const at = (days) => notificationText({ ...base, category: 'important_date', payload: { date_id: 'd', days_left: days }, date_title: 'Anniversary' }).body;
    assert.equal(at(0), 'Anniversary is today.');
    assert.equal(at(1), 'Anniversary is tomorrow.');
    assert.equal(at(7), 'Anniversary is in 7 days.');
  });

  test('a reminder for a date that no longer exists is dropped', () => {
    assert.equal(notificationText({ ...base, category: 'important_date', payload: { days_left: 1 } }), null);
  });

  test('pairing and account events', () => {
    assert.match(notificationText({ ...base, category: 'pairing', payload: { event: 'accepted' } }).body, /Sam accepted/);
    assert.match(notificationText({ ...base, category: 'pairing', payload: { event: 'declined' } }).title, /declined/);
    assert.match(notificationText({ ...base, category: 'account', payload: { event: 'space_ended' } }).body, /unlinked/);
    assert.equal(notificationText({ ...base, category: 'account', payload: { event: 'unknown' } }), null);
  });
});
