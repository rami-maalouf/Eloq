import type { Answer, Result, Sources, Store, Storage } from './app.contract.d.ts';
import { Snapback, refused, type Sent } from './snapback4/snapback.ts';
import { api } from './backend/api.ts';                 // the backend's generated operations (app.json mounts ../snapback/generated)
import { normalize } from './matcher/normalize.ts';     // the one identity of a term (app.json mounts ../packages/matcher/src)

export const appId = 'studio.orbitlabs.eloq.app';         // app.json's "app": { "id" }: change the two together
// the snapback origin: `bun run backend:dev` beside the app in development; a release bakes
// its own with EXACT_BACKEND_ORIGIN.
const origin = 'http://127.0.0.1:4420';
// the session lives in the platform's secret store (the keychain on apple). grants are read at
// build time, so the key is a literal; a development and a release build of the same app id
// share it, so sign in again after switching between them.
const sessionKey = 'eloq-session';
export const grants = `net.fetch ${origin}\nsqlite.open app:/data\nsecret.keep ${sessionKey}`;

type Term = Result<'library'>['terms'][number];
type Link = Result<'library'>['links'][number];
type Reply = Result<'addTerm'>;

const auth = (store: Store, now: number) => ({ store, key: sessionKey, now: Math.floor(now) });

// a client for this app: it restores the stored session and binds that account's partition on
// this device; opened per source, shared while open, kept on close
async function withClient<T>(store: Store, storage: Storage, native: unknown, now: number,
    work: (db: Snapback) => Promise<T>): Promise<T> {
  const db = await Snapback.open({ app: appId, name: 'account', origin, storage, native, auth: auth(store, now) } as never);
  try {
    return await work(db);
  } finally {
    await db.close();
  }
}

// the same, for work that needs a signed-in account
const withDevice = <T>(store: Store, storage: Storage, native: unknown, now: number,
    work: (db: Snapback) => Promise<T>): Promise<T> =>
  withClient(store, storage, native, now, async (db) => {
    if (!db.session) throw refused({ code: 'E_AUTH', message: 'Sign in again.' });
    return work(db);
  });

// a write's fate as the view's reply: sent, or kept on this device until the next sync
function ack(fate: Sent<{ id: string } | null>): Reply {
  if (fate.state === 'failed') throw refused(fate.why);
  const id = fate.state === 'sent' ? fate.result?.id ?? '' : '';
  return { ok: true, id, kept: fate.state !== 'sent' };
}

const text = (v: unknown) => (typeof v === 'string' ? v : '');
const list = (v: unknown) => (Array.isArray(v) ? v.filter((x): x is string => typeof x === 'string') : []);

const sources: Sources = {
  restoreAccount: ([now], store, storage, native): Promise<Result<'restoreAccount'>> =>
    withClient(store, storage, native, now, async (db) => ({ principal: db.session?.principal ?? '' })),

  library: async ([principal, now], store, storage, native): Promise<Result<'library'>> => {
    if (!principal) return { principal: '', online: false, sending: 0, terms: [], links: [] };
    return withDevice(store, storage, native, now, async (db) => {
      if (db.session?.principal !== principal) throw refused({ code: 'E_AUTH', message: 'Sign in again.' });
      const round = await db.sync();
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
      return { principal, online: round.ok, sending, terms, links };
    });
  },

  signup: ([email, password, now], store, storage, native) => withClient(store, storage, native, now, async (db) => {
    const signed = await db.signup(email, password);
    if (!signed.ok) throw refused(signed.why);
    return { ok: true, id: '', kept: false };
  }),
  login: ([email, password, now], store, storage, native) => withClient(store, storage, native, now, async (db) => {
    const signed = await db.login(email, password);
    if (!signed.ok) throw refused(signed.why);
    return { ok: true, id: '', kept: false };
  }),
  logout: ([now], store, storage, native) => withClient(store, storage, native, now, async (db) => {
    await db.logout();                                   // local sign-out always succeeds
    return { ok: true, id: '', kept: false };
  }),

  addTerm: ([word, overused, target, meaning, example, now], store, storage, native) =>
    withDevice(store, storage, native, now, async (db) => ack(await db.send(api.addTerm, {
      text: word.trim(), normalized: normalize(word), overused, target,
      meaning: meaning.trim(), example: example.trim(), notes: '', provenance: 'user',
    }, now))),

  editTerm: ([id, word, overused, target, meaning, nuance, whenNotToUse, example, notes, now], store, storage, native) =>
    withDevice(store, storage, native, now, async (db) => {
      const rows = await db.readAll(api.library, {}, now);
      const old = rows.find((t) => t.id === id);
      if (!old) throw refused({ code: 'NOT_FOUND', message: 'That word is gone.' });
      return ack(await db.send(api.editTerm, {
        term: id, text: word.trim(), normalized: normalize(word), forms: list(old.forms), overused, target,
        meaning: meaning.trim(), nuance: nuance.trim(), whenNotToUse: whenNotToUse.trim(),
        example: example.trim(), notes: notes.trim(), contexts: list(old.contexts), tags: list(old.tags),
      }, now));
    }),

  removeTerm: ([id, now], store, storage, native) =>
    withDevice(store, storage, native, now, async (db) => ack(await db.send(api.removeTerm, { term: id }, now))),

  // the view names the target by its normalized text, which a test can know; its id is minted
  addLink: ([from, toNormalized, useWhen, rationale, now], store, storage, native) =>
    withDevice(store, storage, native, now, async (db) => {
      const target = (await db.readAll(api.library, {}, now)).find((t) => t.normalized === toNormalized);
      if (!target) throw refused({ code: 'NOT_FOUND', message: 'That word is gone.' });
      return ack(await db.send(api.link, {
        from, to: target.id, status: 'accepted', origin: 'user', confidence: 100,
        rationale: rationale.trim(), useWhen: useWhen.trim(), caution: '', example: '',
      }, now));
    }),

  setLinkStatus: ([id, status, now], store, storage, native) =>
    withDevice(store, storage, native, now, async (db) => ack(await db.send(api.setLinkStatus, {
      link: id, status: status as 'suggested' | 'accepted' | 'dismissed',
    }, now))),

  removeLink: ([id, now], store, storage, native) =>
    withDevice(store, storage, native, now, async (db) => ack(await db.send(api.removeLink, { link: id }, now))),
};

export const answer: Answer = (source, args, store, storage, native) =>
  sources[source](args as never, store, storage, native) as never;
