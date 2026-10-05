/**
 * Who can use Ordinary, by hand.
 *
 *   node --env-file=.env scripts/access.mjs <command> ...
 *
 *   who <email>                          what this person gets right now, and why
 *   unlimited <email> [days] [note]      unlimited use (for N days if given, else until removed)
 *   free <email> [note]                  let a non-buyer in on the free 25 a day (team, testers)
 *   remove <email>                       take a grant away (an owner goes back to 25 a day)
 *   revoke <email | orderId> [reason]    take access away (a refused or returned COD order)
 *   unrevoke <email | orderId>           give it back
 *   list                                 everyone with a grant, and everything revoked
 *
 * Changes take effect within ten minutes for someone already signed in, and
 * at once for a new sign-in. Never touches the store's own data.
 */
import { createAccounts, ensureIndexes } from '../src/accounts.js';
import { databases } from '../src/db.js';

const [command, target, ...rest] = process.argv.slice(2);
const usage = () => { console.log('usage: access.mjs who|unlimited|free|remove|revoke|unrevoke|list ...  (see the top of this file)'); process.exit(1); };
if (!command) usage();

const dbs = await databases();
if (!dbs) { console.error('MONGODB_URI is not set.'); process.exit(1); }
await ensureIndexes(dbs.ordinary);
const { admin } = createAccounts({
  store: dbs.store, ordinary: dbs.ordinary, mailer: null,
  secrets: { jwt: process.env.JWT_SECRET ?? 'unused', otp: process.env.OTP_HMAC_SECRET ?? 'unused' },
});

const describe = async (email) => {
  const ent = await admin.entitlementFor(email);
  const what = ent.tier === 'unlimited' ? `unlimited${ent.until ? ` until ${ent.until.toISOString().slice(0, 10)}` : ''}`
    : ent.tier === 'free' ? '25 answers a day' : 'no access';
  console.log(`${email}: ${what} (${ent.reason})`);
};

try {
  switch (command) {
    case 'who':
      if (!target) usage();
      await describe(target);
      break;
    case 'unlimited': {
      if (!target) usage();
      const days = /^\d+$/.test(rest[0] ?? '') ? Number(rest.shift()) : null;
      const until = days ? new Date(Date.now() + days * 86_400_000) : null;
      await admin.grant(target, 'unlimited', { until, note: rest.join(' ') });
      await describe(target);
      break;
    }
    case 'free':
      if (!target) usage();
      await admin.grant(target, 'free', { note: rest.join(' ') });
      await describe(target);
      break;
    case 'remove':
      if (!target) usage();
      await admin.ungrant(target);
      await describe(target);
      break;
    case 'revoke':
      if (!target) usage();
      await admin.revoke(target, rest.join(' '));
      console.log(`revoked: ${target}`);
      if (target.includes('@')) await describe(target);
      break;
    case 'unrevoke':
      if (!target) usage();
      await admin.unrevoke(target);
      console.log(`restored: ${target}`);
      if (target.includes('@')) await describe(target);
      break;
    case 'list': {
      const grants = await dbs.ordinary.collection('grants').find({}).sort({ at: -1 }).toArray();
      console.log(`grants (${grants.length}):`);
      for (const g of grants) console.log(`  ${g.email}  ${g.tier}${g.until ? ` until ${g.until.toISOString().slice(0, 10)}` : ''}${g.note ? `  — ${g.note}` : ''}`);
      const revoked = await dbs.ordinary.collection('revoked').find({}).sort({ at: -1 }).toArray();
      console.log(`revoked (${revoked.length}):`);
      for (const r of revoked) console.log(`  ${r.email ?? `order ${r.orderId}`}${r.reason ? `  — ${r.reason}` : ''}`);
      break;
    }
    default:
      usage();
  }
} finally {
  await dbs.client.close();
}
