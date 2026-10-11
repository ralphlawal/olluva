// Checks a deployed Supabase project through its public API, the way the app
// and an attacker would reach it: four anonymous identities, two couples.
//
//   SUPABASE_HOST=<ref>.supabase.co SUPABASE_KEY=<publishable key> node live-check.mjs
//
// Uses only the publishable key. It creates real rows; the script prints the
// user ids it made so they can be removed afterwards (see TESTING.md).

const host = process.env.SUPABASE_HOST;
const key = process.env.SUPABASE_KEY;
if (!host || !key) throw new Error('Set SUPABASE_HOST and SUPABASE_KEY');
const base = `https://${host}`;

let passed = 0;
const failures = [];
function check(name, ok, detail = '') {
  if (ok) { passed += 1; console.log(`  ok   ${name}`); }
  else { failures.push(name); console.log(`  FAIL ${name} ${detail}`); }
}

async function call(path, { method = 'GET', token, body, headers = {}, raw = false } = {}) {
  const response = await fetch(`${base}${path}`, {
    method,
    headers: {
      apikey: key,
      ...(token ? { authorization: `Bearer ${token}` } : {}),
      ...(body && !raw ? { 'content-type': 'application/json' } : {}),
      ...headers,
    },
    body: body ? (raw ? body : JSON.stringify(body)) : undefined,
  });
  const text = await response.text();
  let json = null;
  try { json = text ? JSON.parse(text) : null; } catch { /* not json */ }
  return { status: response.status, json, text };
}

async function newIdentity(name) {
  const res = await call('/auth/v1/signup', { method: 'POST', body: { data: {} } });
  if (res.status !== 200) throw new Error(`anonymous sign-in failed: ${res.status} ${res.text}`);
  const user = { id: res.json.user.id, token: res.json.access_token, anonymous: res.json.user.is_anonymous };
  await call(`/rest/v1/profiles?id=eq.${user.id}`, { method: 'PATCH', token: user.token, body: { display_name: name } });
  return user;
}
const rpc = (user, fn, args = {}) => call(`/rest/v1/rpc/${fn}`, { method: 'POST', token: user?.token, body: args });

async function pair(nameA, nameB) {
  const a = await newIdentity(nameA);
  const b = await newIdentity(nameB);
  const space = await rpc(a, 'create_couple_space');
  const invite = await rpc(a, 'create_invitation');
  const accepted = await rpc(b, 'accept_invitation', { p_code: invite.json.code });
  return { a, b, coupleId: space.json, invite: invite.json, accepted: accepted.json };
}

console.log('Identity without sign-up');
const one = await pair('LiveAda', 'LiveBen');
check('anonymous sign-in returns an anonymous user', one.a.anonymous === true);
check('pairing through a real invitation works', one.accepted?.ok === true, JSON.stringify(one.accepted));
const two = await pair('LiveCal', 'LiveDee');
console.log(`  created users: ${[one.a, one.b, two.a, two.b].map((u) => u.id).join(' ')}`);

console.log('No identity at all');
const anonTables = await call('/rest/v1/notes?select=id');
check('no token: notes are unreadable', anonTables.status >= 400 || (anonTables.json ?? []).length === 0, `status ${anonTables.status}`);
const anonRpc = await rpc(null, 'create_couple_space');
check('no token: functions are refused', anonRpc.status >= 400, `status ${anonRpc.status}`);

console.log('Notes');
const noteId = crypto.randomUUID();
const sent = await call('/rest/v1/notes?select=*', {
  method: 'POST', token: one.a.token, headers: { prefer: 'return=representation' },
  body: { id: noteId, couple_id: one.coupleId, author_id: one.a.id, body: 'live check: ours' },
});
check('a member can send a note', sent.status === 201, `${sent.status} ${sent.text}`);
const partnerView = await call(`/rest/v1/notes?select=body,author_id&id=eq.${noteId}`, { token: one.b.token });
check('the partner can read it', partnerView.json?.[0]?.body === 'live check: ours');
const again = await call('/rest/v1/notes', {
  method: 'POST', token: one.a.token,
  body: { id: noteId, couple_id: one.coupleId, author_id: one.a.id, body: 'duplicate' },
});
check('sending the same id twice is refused, not duplicated', again.status === 409, `status ${again.status}`);
const forged = await call('/rest/v1/notes?select=author_id', {
  method: 'POST', token: one.a.token, headers: { prefer: 'return=representation' },
  body: { couple_id: one.coupleId, author_id: one.b.id, body: 'pretending to be Ben' },
});
check('a note cannot be written in the partner\'s name', forged.json?.[0]?.author_id === one.a.id, forged.text);
const serverColumn = await call('/rest/v1/notes', {
  method: 'POST', token: one.a.token,
  body: { couple_id: one.coupleId, author_id: one.a.id, body: 'x', seen_at: new Date().toISOString() },
});
check('server-controlled columns cannot be supplied', serverColumn.status >= 400, `status ${serverColumn.status}`);

console.log('Another couple attacking');
const leak = await call(`/rest/v1/notes?select=id&couple_id=eq.${one.coupleId}`, { token: two.a.token });
check('cannot read the other couple\'s notes', (leak.json ?? []).length === 0, leak.text);
const intrude = await call('/rest/v1/notes', {
  method: 'POST', token: two.a.token, body: { couple_id: one.coupleId, author_id: two.a.id, body: 'intrusion' },
});
check('cannot write into the other couple\'s space', intrude.status === 403 || intrude.status === 401, `status ${intrude.status}`);
const edit = await rpc(two.a, 'update_note', {
  p_note_id: noteId, p_expected_version: 1, p_body: 'hijack', p_style: {}, p_photo_path: null, p_drawing_path: null,
});
check('cannot edit the other couple\'s note', edit.status >= 400 && /note_not_found/.test(edit.text), edit.text);
const del = await rpc(two.a, 'delete_note', { p_note_id: noteId });
check('cannot delete the other couple\'s note', del.status >= 400, edit.text);
const direct = await call(`/rest/v1/notes?id=eq.${noteId}`, { method: 'PATCH', token: one.a.token, body: { body: 'direct edit' } });
check('notes cannot be edited with a direct table write, even by their author', direct.status >= 400, `status ${direct.status}`);
const profiles = await call('/rest/v1/profiles?select=display_name', { token: two.a.token });
check('can see only own and partner\'s profile', (profiles.json ?? []).map((p) => p.display_name).sort().join() === 'LiveCal,LiveDee', profiles.text);
const members = await call('/rest/v1/couple_members', {
  method: 'POST', token: two.a.token, body: { couple_id: one.coupleId, user_id: two.a.id },
});
check('membership cannot be written directly', members.status >= 400, `status ${members.status}`);
const subs = await call('/rest/v1/subscriptions', {
  method: 'POST', token: two.a.token,
  body: { original_transaction_id: 'live-fake', user_id: two.a.id, product_id: 'p', status: 'active', environment: 'Production' },
});
check('a subscription cannot be self-granted', subs.status >= 400, `status ${subs.status}`);
const entitlement = await rpc(two.a, 'get_entitlement');
check('entitlement is free', entitlement.json?.is_premium === false, entitlement.text);
const service = await rpc(two.a, 'record_subscription', {
  p_original_transaction_id: 'x', p_user: two.a.id, p_product_id: 'p', p_status: 'active',
  p_expires_at: null, p_auto_renew: true, p_environment: 'Production', p_last_transaction_id: 'x',
});
check('server-only functions are refused', service.status >= 400, `status ${service.status}`);
const hash = await call('/rest/v1/invitations?select=code_hash', { token: one.a.token });
check('invitation hashes are not readable, even by the creator', hash.status >= 400, `status ${hash.status}`);
const reuse = await rpc(two.a, 'accept_invitation', { p_code: one.invite.code });
check('a used invitation cannot be used again', reuse.json?.ok === false, reuse.text);
const tokens = await call('/rest/v1/device_tokens?select=token', { token: one.a.token });
check('device tokens are not readable', tokens.status >= 400, `status ${tokens.status}`);

console.log('Private media (real Storage API)');
const jpeg = Buffer.from('/9j/4AAQSkZJRgABAQEASABIAAD/2wBDAP//////////////////////////////////////////////////////////////////////////////////////wgALCAABAAEBAREA/8QAFBABAAAAAAAAAAAAAAAAAAAAAP/aAAgBAQABPxA=', 'base64');
const path = `couples/${one.coupleId}/${crypto.randomUUID()}.jpg`;
const upload = await call(`/storage/v1/object/couple-media/${path}`, {
  method: 'POST', token: one.a.token, body: jpeg, raw: true, headers: { 'content-type': 'image/jpeg' },
});
check('a member can upload into their couple folder', upload.status === 200, `${upload.status} ${upload.text}`);
const partnerDownload = await call(`/storage/v1/object/authenticated/couple-media/${path}`, { token: one.b.token });
check('the partner can download it', partnerDownload.status === 200, `status ${partnerDownload.status}`);
const strangerDownload = await call(`/storage/v1/object/authenticated/couple-media/${path}`, { token: two.a.token });
check('another couple cannot download it', strangerDownload.status >= 400, `status ${strangerDownload.status}`);
const publicDownload = await call(`/storage/v1/object/public/couple-media/${path}`);
check('it is not publicly reachable', publicDownload.status >= 400, `status ${publicDownload.status}`);
const noTokenDownload = await call(`/storage/v1/object/authenticated/couple-media/${path}`);
check('it is not reachable without an identity', noTokenDownload.status >= 400, `status ${noTokenDownload.status}`);
const foreignUpload = await call(`/storage/v1/object/couple-media/couples/${one.coupleId}/${crypto.randomUUID()}.jpg`, {
  method: 'POST', token: two.a.token, body: jpeg, raw: true, headers: { 'content-type': 'image/jpeg' },
});
check('another couple cannot upload into this folder', foreignUpload.status >= 400, `status ${foreignUpload.status}`);
const overwrite = await call(`/storage/v1/object/couple-media/${path}`, {
  method: 'PUT', token: one.b.token, body: jpeg, raw: true, headers: { 'content-type': 'image/jpeg' },
});
check('an uploaded file cannot be overwritten', overwrite.status >= 400, `status ${overwrite.status}`);
const remove = await call(`/storage/v1/object/couple-media/${path}`, { method: 'DELETE', token: one.a.token });
const stillThere = await call(`/storage/v1/object/authenticated/couple-media/${path}`, { token: one.a.token });
check('a client cannot delete media', stillThere.status === 200, `delete ${remove.status}, then get ${stillThere.status}`);
const html = await call(`/storage/v1/object/couple-media/couples/${one.coupleId}/${crypto.randomUUID()}.jpg`, {
  method: 'POST', token: one.a.token, body: Buffer.from('<html></html>'), raw: true, headers: { 'content-type': 'text/html' },
});
check('a non-image upload is refused', html.status >= 400, `status ${html.status}`);

console.log('Unlinking');
await call('/rest/v1/notes', {
  method: 'POST', token: one.b.token, body: { couple_id: one.coupleId, author_id: one.b.id, body: 'live check: theirs' },
});
await rpc(one.b, 'leave_couple', { p_block_partner: false });
const afterLeave = await call(`/rest/v1/notes?select=id&couple_id=eq.${one.coupleId}`, { token: one.a.token });
check('after unlinking, neither partner can read the space', (afterLeave.json ?? []).length === 0, afterLeave.text);
// Supabase's CDN keeps a copy of a file for the exact session that already
// downloaded it, so the unchanged URL can keep answering for that session
// until its token expires. A fresh query string makes the request reach
// Storage itself, which is where access is decided. See SECURITY.md.
const mediaAfter = await call(`/storage/v1/object/authenticated/couple-media/${path}?nocache=${Date.now()}`, { token: one.a.token });
check('after unlinking, Storage refuses its media', mediaAfter.status >= 400, `status ${mediaAfter.status}`);
const uploadAfter = await call(`/storage/v1/object/couple-media/couples/${one.coupleId}/${crypto.randomUUID()}.jpg`, {
  method: 'POST', token: one.a.token, body: jpeg, raw: true, headers: { 'content-type': 'image/jpeg' },
});
check('after unlinking, nothing more can be uploaded to it', uploadAfter.status >= 400, `status ${uploadAfter.status}`);
const exported = await rpc(one.a, 'export_my_data');
check('export still returns what the person wrote', (exported.json?.notes ?? []).some((n) => n.body === 'live check: ours'), exported.text.slice(0, 120));
check('export does not include what the partner wrote', !exported.text.includes('live check: theirs'));

console.log('Edge Functions');
const purchaseNoToken = await call('/functions/v1/verify-purchase', { method: 'POST', body: { jws: 'x' } });
check('verify-purchase: no token is refused', purchaseNoToken.status === 401, `status ${purchaseNoToken.status}`);
const purchaseBogus = await call('/functions/v1/verify-purchase', { method: 'POST', token: one.a.token, body: { jws: 'x' } });
check('verify-purchase: a signed-in caller is recognised, and a forged transaction is rejected',
  purchaseBogus.status === 400 && purchaseBogus.json?.error === 'verification_failed', `status ${purchaseBogus.status} ${purchaseBogus.text}`);
const entitlementAfter = await rpc(one.a, 'get_entitlement');
check('a rejected transaction grants nothing', entitlementAfter.json?.is_premium === false, entitlementAfter.text);
// Deleting for real: it is the only proof the function recognises its caller,
// and it leaves the project without this run's identities.
for (const person of [one.a, one.b, two.a, two.b]) {
  const removed = await call('/functions/v1/delete-account', { method: 'POST', token: person.token });
  check('delete-account: a signed-in caller is deleted', removed.status === 200, `status ${removed.status} ${removed.text}`);
  const after = await call('/functions/v1/verify-purchase', { method: 'POST', token: person.token, body: { jws: 'x' } });
  check('delete-account: the deleted identity is no longer recognised', after.status === 401, `status ${after.status}`);
}

console.log(`\n${passed} passed, ${failures.length} failed`);
if (failures.length) { console.log(failures.map((f) => ` - ${f}`).join('\n')); process.exit(1); }
