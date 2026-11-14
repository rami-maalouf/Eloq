// the person's snapback session for this mcp server: one file per server url, readable only by
// its owner (0600), refreshed when it is within two days of expiry.
import { chmod, mkdir, readFile, rm, writeFile } from 'node:fs/promises';
import { homedir } from 'node:os';
import { join } from 'node:path';
import { login, refreshSession } from 'snapback4/auth';

export type Session = { token: string; principal: string; kind: string; expiresAt: number };

const REFRESH_WITHIN = 2 * 24 * 60 * 60 * 1000;

function fileFor(url: string): string {
  const dir = process.env.ELOQ_CONFIG_DIR ?? join(homedir(), '.config', 'eloq');
  const name = url.replace(/^https?:\/\//, '').replace(/[^a-z0-9.-]/gi, '-').toLowerCase();
  return join(dir, `session-${name}.json`);
}

async function save(url: string, session: Session): Promise<void> {
  const file = fileFor(url);
  await mkdir(join(file, '..'), { recursive: true, mode: 0o700 });
  await writeFile(file, JSON.stringify(session), { mode: 0o600 });
  await chmod(file, 0o600);
}

function shape(raw: unknown): Session | null {
  const s = raw as Partial<Session> | null;
  if (!s || typeof s.token !== 'string' || typeof s.principal !== 'string') return null;
  const expiresAt = typeof s.expiresAt === 'number' ? s.expiresAt : Date.parse(String(s.expiresAt));
  return { token: s.token, principal: s.principal, kind: s.kind ?? 'password', expiresAt };
}

export async function signIn(url: string, email: string, password: string): Promise<Session> {
  const signed = await login(url, email, password);
  if (!signed.ok) throw new Error(`${signed.why.code}: ${signed.why.message}`);
  const session = shape(signed.session);
  if (!session) throw new Error('the server returned no session');
  await save(url, session);
  return session;
}

export async function signOut(url: string): Promise<void> {
  await rm(fileFor(url), { force: true });
}

// the stored session, refreshed if it is close to expiry; null when there is none or it is gone
export async function currentSession(url: string, now = Date.now()): Promise<Session | null> {
  let session: Session | null;
  try {
    session = shape(JSON.parse(await readFile(fileFor(url), 'utf8')));
  } catch {
    return null;
  }
  if (!session) return null;
  if (session.expiresAt - now > REFRESH_WITHIN) return session;
  const renewed = await refreshSession(url, session.token);
  if (renewed.ok) {
    const next = shape(renewed.session);
    if (next) {
      await save(url, next);
      return next;
    }
  }
  // offline near expiry: keep using the old token until it is refused
  return session.expiresAt > now ? session : null;
}
