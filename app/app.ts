import type { Answer, Result, Sources } from './app.contract.d.ts';
import { Snapback, refused, pick, type Sent } from './snapback4/snapback.ts';
import { api } from './backend/api.ts';                 // the backend's generated operations (app.json mounts ../snapback/generated)

export const appId = 'com.example.app-802a7b';            // app.json's "app": { "id" }: change the two together
// The Snapback origin: `snapback4 dev --port 4420` in the directory above, and the tests' fetch prefixes.
const origin = 'http://127.0.0.1:4420';
export const grants = `net.fetch ${origin}\nsqlite.open app:/data`;

// One partition open at a time: switching persona waits for the other's work in flight, then closes its partition.
const personas = Snapback.switcher((persona: string) => ({ app: appId, name: `app-${persona}`, origin,
  viewer: `dev:${persona}`, headers: () => ({ 'x-snapback-persona': persona }) }));

function ack(fate: Sent<{id: string} | null>): Result<'post'> {
  if (fate.state === 'failed') throw refused(fate.why);
  if (fate.state === 'sent') return {ok: true, message: 'Posted.', id: fate.result?.id ?? ''};
  return {ok: true, message: 'Saved on this device; it sends when online.', id: ''};
}
const note = pick<Result<'notes'>['notes'][number]>();

const sources: Sources = {
  notes: ([persona, now], _store, storage, native) => personas.use(persona, storage, native, async (db): Promise<Result<'notes'>> => {
    const round = await db.sync();                      // offline is fine once synced
    const read = await db.read(api.recent, {}, now);
    if (read.denied) throw refused(read.denied);        // failure(board): `offline`, or `error` with the refusal's code as `reason`
    // Project each row onto the shape: an answer's extra fields are refused.
    const notes = (read.data ?? []).map(row => note({...row, pending: row.pending === true}, 'id', 'author', 'body', 'pending'));
    return { online: round.ok, message: round.ok ? '' : 'Offline: showing what this device keeps',
      latest: notes.length ? `${notes[0].author}: ${notes[0].body}` : '',
      sending: notes.filter(note => note.pending).length, notes };
  }),
  post: ([persona, body, now], _store, storage, native) => personas.use(persona, storage, native, async (db): Promise<Result<'post'>> => {
    // Write, sync and the write's fate in one call: `sent`, `failed` with the refusal's code, or `pending` (kept; sent later).
    return ack(await db.send(api.post, { body }, now));
  }),
};
export const answer: Answer = (source, args, store, storage, native) =>
  sources[source](args, store, storage, native);
