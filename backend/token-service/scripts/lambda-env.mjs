/**
 * Copies the account settings from .env into the Lambda's environment, on top
 * of what it already has. Prints names only, never values.
 *
 *   node --env-file=.env scripts/lambda-env.mjs [KEY=value ...]
 *
 * Extra KEY=value pairs override .env (e.g. MAIL_MODE=log, AUTH_REQUIRED=true);
 * KEY= with nothing after it removes that variable.
 */
import { execFileSync } from 'node:child_process';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

const FN = process.env.LAMBDA_FUNCTION ?? 'ordi-token';
const REGION = process.env.AWS_REGION_NAME ?? 'ap-south-1';
const COPY = ['MONGODB_URI', 'STORE_DB', 'ORDINARY_DB', 'JWT_SECRET', 'OTP_HMAC_SECRET', 'RESEND_API_KEY', 'MAIL_FROM', 'DAILY_CREDITS', 'AUTH_REQUIRED', 'REVIEW_EMAIL', 'REVIEW_CODE'];

const aws = (args) => execFileSync('aws', [...args, '--region', REGION], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] });
const current = JSON.parse(aws(['lambda', 'get-function-configuration', '--function-name', FN, '--query', 'Environment.Variables', '--output', 'json'])) ?? {};

const next = { ...current };
for (const key of COPY) if (process.env[key]) next[key] = process.env[key];
for (const pair of process.argv.slice(2)) {
  const at = pair.indexOf('=');
  if (at < 1) continue;
  const key = pair.slice(0, at); const value = pair.slice(at + 1);
  if (value === '') delete next[key]; else next[key] = value;
}

const dir = mkdtempSync(join(tmpdir(), 'lambda-env-'));
const file = join(dir, 'env.json');
try {
  writeFileSync(file, JSON.stringify({ Variables: next }), { mode: 0o600 });
  aws(['lambda', 'update-function-configuration', '--function-name', FN, '--environment', `file://${file}`, '--query', 'LastUpdateStatus', '--output', 'text']);
  aws(['lambda', 'wait', 'function-updated', '--function-name', FN]);
} finally {
  rmSync(dir, { recursive: true, force: true });
}
const added = Object.keys(next).filter((k) => !(k in current));
const removed = Object.keys(current).filter((k) => !(k in next));
console.log('variables now set:', Object.keys(next).sort().join(', '));
console.log('added:', added.join(', ') || 'none', '| removed:', removed.join(', ') || 'none');
