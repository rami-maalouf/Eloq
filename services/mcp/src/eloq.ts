// eloq's data as agents see it: terms and links by text, every write through the server's own
// mutations (the same rules and refusals the app gets).
import { createClient } from 'snapback4/client';
import { api } from '../../../snapback/generated/api.ts';
import { normalize } from '../../../packages/matcher/src/index.ts';
import type { Session } from './session.ts';

type Row = Record<string, unknown>;

export class EloqError extends Error {
  constructor(readonly code: string, message: string) { super(message); }
}

export type Term = {
  id: string; text: string; normalized: string; overused: boolean; target: boolean; meaning: string;
  nuance: string; whenNotToUse: string; example: string; notes: string; forms: string[];
  contexts: string[]; tags: string[]; provenance: string; sourceExcerpt: string;
};
export type Link = {
  id: string; from: string; to: string; fromText: string; toText: string; status: string; origin: string;
  confidence: number; rationale: string; useWhen: string; caution: string; example: string;
};

const str = (v: unknown) => (typeof v === 'string' ? v : '');
const strs = (v: unknown) => (Array.isArray(v) ? v.filter((x): x is string => typeof x === 'string') : []);

function term(r: Row): Term {
  return {
    id: str(r.id), text: str(r.text), normalized: str(r.normalized), overused: r.overused === true,
    target: r.target === true, meaning: str(r.meaning), nuance: str(r.nuance), whenNotToUse: str(r.whenNotToUse),
    example: str(r.example), notes: str(r.notes), forms: strs(r.forms), contexts: strs(r.contexts),
    tags: strs(r.tags), provenance: str(r.provenance), sourceExcerpt: str(r.sourceExcerpt),
  };
}

export class Eloq {
  private client;
  constructor(url: string, session: Session) {
    this.client = createClient({ url, session });
  }

  async close(): Promise<void> { await this.client.close(); }

  private async read<T>(op: unknown, args: unknown): Promise<T[]> {
    const read = await this.client.query(op as never, args as never) as { data?: T[]; denied?: { code: string; message: string } };
    if ('denied' in read && read.denied) throw new EloqError(read.denied.code, read.denied.message);
    return read.data ?? [];
  }

  private async write<R>(op: unknown, args: unknown): Promise<R> {
    const w = await this.client.mutate(op as never, args as never) as
      { state: string; result?: R; why?: { code: string; message: string }; reason?: string };
    if (w.state === 'sent') return w.result as R;
    if (w.why) throw new EloqError(w.why.code, w.why.message);
    throw new EloqError('E_OFFLINE', `the eloq server did not take the write (${w.state}${w.reason ? `: ${w.reason}` : ''}); try again`);
  }

  async terms(): Promise<Term[]> {
    return (await this.read<Row>(api.library, {})).map(term)
      .sort((a, b) => a.normalized.localeCompare(b.normalized));
  }

  async links(): Promise<Link[]> {
    const [terms, rows] = await Promise.all([this.terms(), this.read<Row>(api.allLinks, {})]);
    const text = new Map(terms.map((t) => [t.id, t.text]));
    return rows.map((l) => ({
      id: str(l.id), from: str(l.from), to: str(l.to), fromText: text.get(str(l.from)) ?? '',
      toText: text.get(str(l.to)) ?? '', status: str(l.status), origin: str(l.origin),
      confidence: typeof l.confidence === 'number' ? l.confidence : 0, rationale: str(l.rationale),
      useWhen: str(l.useWhen), caution: str(l.caution), example: str(l.example),
    }));
  }

  // a term by its id or its text (any case, spacing or apostrophe)
  async find(ref: string, terms?: Term[]): Promise<Term> {
    const all = terms ?? await this.terms();
    const n = normalize(ref);
    const found = all.find((t) => t.id === ref) ?? all.find((t) => t.normalized === n);
    if (!found) throw new EloqError('NOT_FOUND', `"${ref}" is not in the library`);
    return found;
  }

  async addTerm(input: Partial<Term> & { text: string; overused: boolean; target: boolean }): Promise<Term> {
    if (!input.overused && !input.target) throw new EloqError('E_INPUT', 'a term is overused, a target, or both');
    const result = await this.write<{ id: string }>(api.importTerm, {
      text: input.text.trim(), normalized: normalize(input.text), forms: input.forms ?? [],
      overused: input.overused, target: input.target, meaning: input.meaning ?? '', nuance: input.nuance ?? '',
      whenNotToUse: input.whenNotToUse ?? '', example: input.example ?? '', notes: input.notes ?? '',
      contexts: input.contexts ?? [], tags: input.tags ?? [], provenance: 'agent',
      sourceExcerpt: input.sourceExcerpt ?? '', externalIds: [],
    });
    return this.find(result.id);
  }

  async updateTerm(ref: string, patch: Partial<Term>): Promise<Term> {
    const old = await this.find(ref);
    const next = { ...old, ...Object.fromEntries(Object.entries(patch).filter(([, v]) => v !== undefined)) } as Term;
    if (!next.overused && !next.target) throw new EloqError('E_INPUT', 'a term is overused, a target, or both');
    await this.write(api.editTerm, {
      term: old.id, text: next.text.trim(), normalized: normalize(next.text), forms: next.forms,
      overused: next.overused, target: next.target, meaning: next.meaning, nuance: next.nuance,
      whenNotToUse: next.whenNotToUse, example: next.example, notes: next.notes, contexts: next.contexts, tags: next.tags,
    });
    return this.find(old.id);
  }

  async removeTerm(ref: string): Promise<Term> {
    const old = await this.find(ref);
    await this.write(api.removeTerm, { term: old.id });
    return old;
  }

  async link(input: { from: string; to: string; status: 'suggested' | 'accepted' | 'dismissed'; confidence: number;
      rationale?: string; useWhen?: string; caution?: string; example?: string }): Promise<Link> {
    const terms = await this.terms();
    const from = await this.find(input.from, terms), to = await this.find(input.to, terms);
    const result = await this.write<{ id: string }>(api.importLink, {
      from: from.id, to: to.id, status: input.status, origin: 'agent', confidence: input.confidence,
      rationale: input.rationale ?? '', useWhen: input.useWhen ?? '', caution: input.caution ?? '',
      example: input.example ?? '', sourceExcerpt: '', externalIds: [],
    });
    const made = (await this.links()).find((l) => l.id === result.id);
    if (!made) throw new EloqError('E_OFFLINE', 'the link was written but could not be read back');
    return made;
  }

  async findLink(ref: string): Promise<Link> {
    const links = await this.links();
    const byId = links.find((l) => l.id === ref);
    if (byId) return byId;
    const [a, b] = ref.split(/\s*(?:->|→)\s*/);
    if (a && b) {
      const found = links.find((l) => normalize(l.fromText) === normalize(a) && normalize(l.toText) === normalize(b));
      if (found) return found;
    }
    throw new EloqError('NOT_FOUND', `no link "${ref}" (use its id, or "from -> to")`);
  }

  async setLinkStatus(ref: string, status: 'suggested' | 'accepted' | 'dismissed'): Promise<Link> {
    const link = await this.findLink(ref);
    await this.write(api.setLinkStatus, { link: link.id, status });
    return { ...link, status };
  }

  async editLink(ref: string, patch: { rationale?: string; useWhen?: string; caution?: string; example?: string }): Promise<Link> {
    const link = await this.findLink(ref);
    const next = { ...link, ...Object.fromEntries(Object.entries(patch).filter(([, v]) => v !== undefined)) };
    await this.write(api.editLink, { link: link.id, rationale: next.rationale, useWhen: next.useWhen, caution: next.caution, example: next.example });
    return next;
  }

  async removeLink(ref: string): Promise<Link> {
    const link = await this.findLink(ref);
    await this.write(api.removeLink, { link: link.id });
    return link;
  }

  async addUsage(input: { term: string; day: string; channel: 'typing' | 'speech';
      kind: 'overused_seen' | 'swapped' | 'kept' | 'target_used'; source: string; count: number }): Promise<void> {
    await this.write(api.addUsage, input);
  }

  async recordScan(input: { sourceKind: 'obsidian' | 'speech' | 'letterly'; sourceRef: string; contentHash: string;
      day: string; wordCount: number }): Promise<void> {
    await this.write(api.recordScan, input);
  }

  async scans(): Promise<Array<{ sourceKind: string; sourceRef: string; contentHash: string; day: string; wordCount: number }>> {
    return (await this.read<Row>(api.recentScans, {})).map((s) => ({
      sourceKind: str(s.sourceKind), sourceRef: str(s.sourceRef), contentHash: str(s.contentHash),
      day: str(s.day), wordCount: typeof s.wordCount === 'number' ? s.wordCount : 0,
    }));
  }

  async usageSince(day: string): Promise<Array<{ term: string; day: string; channel: string; kind: string; source: string; count: number }>> {
    const out: Array<{ term: string; day: string; channel: string; kind: string; source: string; count: number }> = [];
    let cursor: unknown = null;
    for (let page = 0; page < 200; page++) {
      const read = await this.client.query(api.usageSince as never, { day, c: cursor } as never) as
        { data?: Row[]; denied?: { code: string; message: string }; next?: unknown; cursor?: unknown; more?: boolean };
      if (read.denied) throw new EloqError(read.denied.code, read.denied.message);
      for (const u of read.data ?? []) {
        out.push({ term: str(u.term), day: str(u.day), channel: str(u.channel), kind: str(u.kind), source: str(u.source),
          count: typeof u.count === 'number' ? u.count : 0 });
      }
      const next = read.next ?? read.cursor;
      if (!next || (read.data ?? []).length === 0) break;
      cursor = next;
    }
    return out;
  }
}
