import type { Answer, Result, Sources, Store, Storage } from './app.contract.d.ts';
import { Snapback, refused, type Write } from './snapback4/snapback.ts';
import { api } from './backend/api.ts';                 // the backend's generated operations (app.json mounts ../snapback/generated)
import { buildIndex, normalize, tableForTyping } from './matcher/index.ts'; // the one identity of a term and the typing table (app.json mounts ../packages/matcher/src)

export const appId = 'studio.orbitlabs.eloq.app';         // app.json's "app": { "id" }: change the two together
// the snapback server. development and the tests select the local one (`bun run backend:dev`)
// through the ignored .exact/backend-origin, or EXACT_BACKEND_ORIGIN at build time.
const origin = 'https://eloq.orbitlabs.studio';
// the session lives in the platform's secret store (the keychain on apple). grants are read at
// build time, so the key is a literal; a development and a release build of the same app id
// share it, so sign in again after switching between them.
const sessionKey = 'eloq-session';
export const grants = `net.fetch ${origin}\nsqlite.open app:/data\nsecret.keep ${sessionKey}\nfs.write app:/data/snapshot.json`;

type Term = Result<'library'>['terms'][number];
type Link = Result<'library'>['links'][number];
type Reply = Result<'addTerm'>;

const auth = (store: Store, now: number) => ({ store, key: sessionKey, now: Math.floor(now) });

// one client for the account, kept open across answers: it restores the stored session and binds
// that account's partition on this device. closing it after every answer would retire the
// partition while another source still reads it.
let current = auth({} as Store, 0);
const account = Snapback.switcher(() => ({ app: appId, name: 'account', origin, auth: current }));

async function withClient<T>(store: Store, storage: Storage, native: unknown, now: number,
    work: (db: Snapback) => Promise<T>): Promise<T> {
  current = auth(store, now);
  const run = () => account.use('account', storage, native as never, async (db) => {
    // the held client keeps the secret store and time of the answer that asks
    if (db.options.auth) Object.assign(db.options.auth, current);
    return work(db);
  }, current.now);
  try {
    return await run();
  } catch (e) {
    // the held client's partition belongs to another session than the one stored now (a sign-in
    // or sign-out through another handle): open a fresh client for the stored session, once
    if ((e as { code?: string })?.code !== 'E_AUTH') throw e;
    await account.close(current.now);
    return run();
  }
}

// the same, for work that needs a signed-in account
const withDevice = <T>(store: Store, storage: Storage, native: unknown, now: number,
    work: (db: Snapback) => Promise<T>): Promise<T> =>
  withClient(store, storage, native, now, async (db) => {
    if (!db.session) throw refused({ code: 'E_AUTH', message: 'Sign in again.' });
    return work(db);
  });

// a write as the view's reply. writes only admit: the device keeps and predicts them at once and
// the mutation's `refreshes lib` syncs. a source never waits on a round, because natively a
// continuation that resumes on another answer's round cannot reach the device
// (docs/agent-pitfalls.md, "native call outside an answer").
function ack(write: Write): Reply {
  if (write.state === 'failed') throw refused(write.why);
  return { ok: true, id: write.newIds[0] ?? '', kept: true };
}

const text = (v: unknown) => (typeof v === 'string' ? v : '');

// what the typing overlay needs: the matcher's table of overused words, and each one's accepted
// moves (the targets to offer, first the one with the highest confidence)
function typingTable(terms: Term[], links: Link[]) {
  const table = tableForTyping(buildIndex(terms.filter((t) => t.overused).map((t) => ({ id: t.id, text: t.text, forms: t.forms }))));
  const moves: Record<string, Array<{ id: string; text: string; useWhen: string }>> = {};
  for (const l of [...links].sort((a, b) => b.confidence - a.confidence)) {
    if (l.status !== 'accepted' || !l.toText) continue;
    (moves[l.from] ??= []).push({ id: l.to, text: l.toText, useWhen: l.useWhen });
  }
  return { ...table, moves };
}

// app:/data/snapshot.json: what other programs on this mac read without the app's database: the
// old eloq app's snapshot (version 1) for the browser extension and obsidian plugin, plus the
// typing table for the typing overlay. written only when it changes.
let lastExport = '';
async function exportSnapshot(storage: Storage, terms: Term[], links: Link[], now: number) {
  const roles = (t: Term) => [...(t.overused ? ['overused'] : []), ...(t.target ? ['underused'] : [])];
  const words = terms.map((t) => ({
    id: t.id, displayTerm: t.text, normalizedTerm: t.normalized, roles: roles(t), notes: t.notes,
    contexts: t.contexts, exampleUsage: t.example, provenance: t.provenance, sourceExcerpt: '',
  }));
  const connections = links.map((l) => ({
    id: l.id, overusedWordID: l.from, overusedTerm: l.fromText, underusedWordID: l.to, underusedTerm: l.toText,
    origin: l.origin, status: l.status, rationale: l.rationale, useWhen: l.useWhen, caution: l.caution,
    sourceExcerpt: '', exampleUsage: l.example, confidence: l.confidence / 100,
  }));
  const count = (s: string) => links.filter((l) => l.status === s).length;
  const body = {
    version: 1,
    summary: {
      totalWords: terms.length, overusedWords: terms.filter((t) => t.overused).length,
      underusedWords: terms.filter((t) => t.target).length, acceptedConnections: count('accepted'),
      suggestedConnections: count('suggested'), dismissedConnections: count('dismissed'),
    },
    words, connections,
    typing: typingTable(terms, links),
  };
  const key = JSON.stringify(body);
  if (key === lastExport) return;
  const text = JSON.stringify({ ...body, generatedAt: new Date(Math.floor(now)).toISOString() }, null, 1);
  await storage.fs.atomicWriteFile('app:/data/snapshot.json', new TextEncoder().encode(text));
  lastExport = key;
}

// a day as YYYY-MM-DD in utc, and the monday that starts its week
const dayOf = (ms: number) => new Date(ms).toISOString().slice(0, 10);
const weekOf = (day: string) => {
  const d = new Date(`${day}T00:00:00Z`);
  return dayOf(d.getTime() - ((d.getUTCDay() + 6) % 7) * 86_400_000);
};

// counts of the last eight weeks from what this device keeps: per word this week, and per week
async function progress(db: Snapback, terms: Term[], now: number) {
  const thisWeek = weekOf(dayOf(now));
  const since = dayOf(new Date(`${thisWeek}T00:00:00Z`).getTime() - 7 * 7 * 86_400_000);
  const usage = await db.readAll(api.usageSince, { day: since }, now);
  const scans = await db.readAll(api.recentScans, {}, now);
  const byId = new Map(terms.map((t) => [t.id, t]));
  const weeks = new Map<string, { start: string; spokenWords: number; overused: number; targets: number }>();
  const week = (start: string) => weeks.get(start) ?? (weeks.set(start, { start, spokenWords: 0, overused: 0, targets: 0 }), weeks.get(start)!);
  for (const s of scans) if (s.day >= since && s.sourceKind !== 'obsidian') week(weekOf(s.day)).spokenWords += s.wordCount;
  const per = new Map<string, Result<'library'>['stats'][number]>();
  for (const u of usage) {
    const w = week(weekOf(u.day));
    if (u.kind === 'overused_seen') w.overused += u.count;
    if (u.kind === 'target_used') w.targets += u.count;
    if (weekOf(u.day) !== thisWeek) continue;
    const t = byId.get(String(u.term));
    if (!t) continue;
    const row = per.get(t.id) ?? { id: t.id, text: t.text, overused: t.overused, said: 0, typed: 0, swapped: 0, targetUsed: 0, per1000: 0 };
    if (u.kind === 'overused_seen') u.channel === 'speech' ? (row.said += u.count) : (row.typed += u.count);
    if (u.kind === 'swapped') row.swapped += u.count;
    if (u.kind === 'target_used') row.targetUsed += u.count;
    per.set(t.id, row);
  }
  const spokenWords = weeks.get(thisWeek)?.spokenWords ?? 0;
  const stats = [...per.values()]
    .map((r) => ({ ...r, per1000: spokenWords ? Math.round((r.said / spokenWords) * 10_000) / 10 : 0 }))
    .sort((a, b) => (b.said + b.typed + b.targetUsed) - (a.said + a.typed + a.targetUsed));
  return { stats, weeks: [...weeks.values()].sort((a, b) => (a.start < b.start ? 1 : -1)), spokenWords };
}
const list = (v: unknown) => (Array.isArray(v) ? v.filter((x): x is string => typeof x === 'string') : []);

const sources: Sources = {
  // everything the view shows, in one answer: the signed-in account and its words and links
  library: ([now], store, storage, native): Promise<Result<'library'>> =>
    withClient(store, storage, native, now, async (db) => {
      const principal = db.session?.principal ?? '';
      const signedOut = { principal: '', online: false, sending: 0, terms: [], links: [], stats: [], weeks: [], spokenWords: 0, typing: '' };
      if (!principal) return signedOut;
      // the server no longer takes this session (revoked, expired, or the account is gone):
      // forget it here and show sign-in; what this device keeps stays for that account
      const round = await db.sync();
      if (round.denied?.code === 'E_AUTH') {
        await db.logout();
        return signedOut;
      }
      const termRows = await db.readAll(api.library, {}, now);
      const linkRows = await db.readAll(api.allLinks, {}, now);
      const terms: Term[] = termRows
        .map((t) => ({
          id: t.id, text: t.text, normalized: t.normalized, overused: t.overused, target: t.target,
          meaning: text(t.meaning), nuance: text(t.nuance), whenNotToUse: text(t.whenNotToUse),
          example: text(t.example), notes: text(t.notes), forms: list(t.forms),
          contexts: list(t.contexts), tags: list(t.tags), provenance: text(t.provenance),
          pending: (t as { pending?: boolean }).pending === true,
        }))
        .sort((a, b) => (a.normalized < b.normalized ? -1 : a.normalized > b.normalized ? 1 : 0));
      const byId = new Map(terms.map((t) => [t.id, t.text]));
      const links: Link[] = linkRows.map((l) => ({
        id: l.id, from: String(l.from), to: String(l.to),
        fromText: byId.get(String(l.from)) ?? '', toText: byId.get(String(l.to)) ?? '',
        status: l.status, origin: l.origin, confidence: l.confidence,
        rationale: text(l.rationale), useWhen: text(l.useWhen), caution: text(l.caution), example: text(l.example),
        pending: (l as { pending?: boolean }).pending === true,
      }));
      const sending = terms.filter((t) => t.pending).length + links.filter((l) => l.pending).length;
      const { stats, weeks, spokenWords } = await progress(db, terms, now);
      await exportSnapshot(storage, terms, links, now);
      return { principal, online: round.ok, sending, terms, links, stats, weeks, spokenWords, typing: JSON.stringify(typingTable(terms, links)) };
    }),

  signup: ([email, password, now], store, storage, native) => withClient(store, storage, native, now, async (db) => {
    if (db.session) await db.logout();                   // a leftover session would refuse a new sign-in
    const signed = await db.signup(email, password);
    if (!signed.ok) throw refused(signed.why);
    return { ok: true, id: '', kept: false };
  }),
  login: ([email, password, now], store, storage, native) => withClient(store, storage, native, now, async (db) => {
    if (db.session) await db.logout();
    const signed = await db.login(email, password);
    if (!signed.ok) throw refused(signed.why);
    return { ok: true, id: '', kept: false };
  }),
  logout: ([now], store, storage, native) => withClient(store, storage, native, now, async (db) => {
    await db.logout();                                   // local sign-out always succeeds
    return { ok: true, id: '', kept: false };
  }),

  addTerm: ([word, overused, target, meaning, example, now], store, storage, native) =>
    withDevice(store, storage, native, now, async (db) => ack(await db.write(api.addTerm, {
      text: word.trim(), normalized: normalize(word), overused, target,
      meaning: meaning.trim(), example: example.trim(), notes: '', provenance: 'user',
    }, now))),

  editTerm: ([id, word, overused, target, meaning, nuance, whenNotToUse, example, notes, now], store, storage, native) =>
    withDevice(store, storage, native, now, async (db) => {
      const rows = await db.readAll(api.library, {}, now);
      const old = rows.find((t) => t.id === id);
      if (!old) throw refused({ code: 'NOT_FOUND', message: 'That word is gone.' });
      return ack(await db.write(api.editTerm, {
        term: id, text: word.trim(), normalized: normalize(word), forms: list(old.forms), overused, target,
        meaning: meaning.trim(), nuance: nuance.trim(), whenNotToUse: whenNotToUse.trim(),
        example: example.trim(), notes: notes.trim(), contexts: list(old.contexts), tags: list(old.tags),
      }, now));
    }),

  removeTerm: ([id, now], store, storage, native) =>
    withDevice(store, storage, native, now, async (db) => ack(await db.write(api.removeTerm, { term: id }, now))),

  // the view names the target by its normalized text, which a test can know; its id is minted
  addLink: ([from, toNormalized, useWhen, rationale, now], store, storage, native) =>
    withDevice(store, storage, native, now, async (db) => {
      const target = (await db.readAll(api.library, {}, now)).find((t) => t.normalized === toNormalized);
      if (!target) throw refused({ code: 'NOT_FOUND', message: 'That word is gone.' });
      return ack(await db.write(api.link, {
        from, to: target.id, status: 'accepted', origin: 'user', confidence: 100,
        rationale: rationale.trim(), useWhen: useWhen.trim(), caution: '', example: '',
      }, now));
    }),

  // the typing overlay saw an overused word, swapped it, or the person kept it: a count for
  // today, by app; never the text
  recordTyping: ([kind, term, app, now], store, storage, native) =>
    withDevice(store, storage, native, now, async (db) => ack(await db.write(api.addUsage, {
      term, day: dayOf(now), channel: 'typing', kind: kind as 'overused_seen' | 'swapped' | 'kept',
      source: (app || 'unknown').slice(0, 160), count: 1,
    }, now))),

  setLinkStatus: ([id, status, now], store, storage, native) =>
    withDevice(store, storage, native, now, async (db) => ack(await db.write(api.setLinkStatus, {
      link: id, status: status as 'suggested' | 'accepted' | 'dismissed',
    }, now))),

  removeLink: ([id, now], store, storage, native) =>
    withDevice(store, storage, native, now, async (db) => ack(await db.write(api.removeLink, { link: id }, now))),
};

export const answer: Answer = (source, args, store, storage, native) =>
  sources[source](args as never, store, storage, native) as never;
