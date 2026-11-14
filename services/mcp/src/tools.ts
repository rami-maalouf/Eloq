// the tools agents call. reads return terms and links by text; writes go through the server's
// mutations, so an agent is refused exactly where the app would be.
import { createHash } from 'node:crypto';
import type { CallToolResult, McpServer } from '@modelcontextprotocol/server';
import { z } from 'zod';
import { buildIndex, countWords, maskMarkdown, scan } from '../../../packages/matcher/src/index.ts';
import { EloqError, type Eloq, type Link, type Term } from './eloq.ts';

const MAX_RESULT_BYTES = 100_000;
const status = z.enum(['suggested', 'accepted', 'dismissed']);
const day = z.string().regex(/^\d{4}-\d{2}-\d{2}$/, 'a day as YYYY-MM-DD');

function reply(value: unknown): CallToolResult {
  const text = JSON.stringify(value, null, 1);
  if (text.length > MAX_RESULT_BYTES) {
    return { isError: true, content: [{ type: 'text', text: 'E_TOO_LARGE: narrow the request (a query, a role or a limit)' }] };
  }
  return { content: [{ type: 'text', text }] };
}

function failure(e: unknown): CallToolResult {
  const code = e instanceof EloqError ? e.code : 'E_UNAVAILABLE';
  const message = e instanceof Error ? e.message : String(e);
  return { isError: true, content: [{ type: 'text', text: `${code}: ${message}` }] };
}

// a compact term for lists: what an agent needs to decide, without every long field
const brief = (t: Term) => ({ id: t.id, text: t.text, overused: t.overused, target: t.target, meaning: t.meaning });

export function registerTools(server: McpServer, open: () => Promise<Eloq>): void {
  const tool = <S extends z.ZodRawShape>(name: string, description: string, input: S,
      run: (args: z.infer<z.ZodObject<S>>, eloq: Eloq) => Promise<unknown>,
      hints: { readOnly?: boolean; destructive?: boolean } = {}) => {
    server.registerTool(name, {
      description,
      inputSchema: z.object(input),
      annotations: { readOnlyHint: hints.readOnly ?? false, destructiveHint: hints.destructive ?? false, openWorldHint: false },
    }, (async (args: z.infer<z.ZodObject<S>>) => {
      let eloq: Eloq | undefined;
      try {
        eloq = await open();
        return reply(await run(args, eloq));
      } catch (e) {
        return failure(e);
      } finally {
        await eloq?.close().catch(() => undefined);
      }
    }) as never);
  };

  tool('search_terms',
    'Find words and phrases in the library. Filter by role (overused words the person wants to stop leaning on, or target words they want to use more) and by text in the word or its meaning.',
    { query: z.string().optional(), role: z.enum(['all', 'overused', 'target']).default('all'), limit: z.number().int().min(1).max(500).default(100) },
    async ({ query, role, limit }, eloq) => {
      const q = (query ?? '').trim().toLowerCase();
      const terms = (await eloq.terms())
        .filter((t) => role === 'all' || (role === 'overused' ? t.overused : t.target))
        .filter((t) => !q || t.normalized.includes(q) || t.meaning.toLowerCase().includes(q));
      return { total: terms.length, terms: terms.slice(0, limit).map(brief) };
    }, { readOnly: true });

  tool('get_term',
    'One word with every field, the target words to use instead of it, and the overused words it replaces.',
    { term: z.string().describe('the word, or its id') },
    async ({ term }, eloq) => {
      const t = await eloq.find(term);
      const links = await eloq.links();
      const out = (l: Link) => ({ id: l.id, word: l.toText, status: l.status, useWhen: l.useWhen, caution: l.caution, rationale: l.rationale, example: l.example });
      const inn = (l: Link) => ({ id: l.id, word: l.fromText, status: l.status, useWhen: l.useWhen, caution: l.caution, rationale: l.rationale, example: l.example });
      return { ...t, useInstead: links.filter((l) => l.from === t.id).map(out), replaces: links.filter((l) => l.to === t.id).map(inn) };
    }, { readOnly: true });

  tool('list_links',
    'Moves from an overused word to a target word. `suggested` ones wait in the app\'s Inbox for the person to accept or dismiss.',
    { status: z.enum(['all', 'suggested', 'accepted', 'dismissed']).default('accepted'), limit: z.number().int().min(1).max(1000).default(200) },
    async ({ status: s, limit }, eloq) => {
      const links = (await eloq.links()).filter((l) => s === 'all' || l.status === s);
      return { total: links.length, links: links.slice(0, limit).map((l) => ({ id: l.id, from: l.fromText, to: l.toText, status: l.status, origin: l.origin, confidence: l.confidence, useWhen: l.useWhen, caution: l.caution, rationale: l.rationale })) };
    }, { readOnly: true });

  tool('add_term',
    'Add a word or phrase. It must be overused, a target, or both. Refused with TERM_EXISTS if the library already has it.',
    {
      text: z.string().min(1).max(120), overused: z.boolean(), target: z.boolean(),
      meaning: z.string().max(2000).optional(), nuance: z.string().max(2000).optional(),
      whenNotToUse: z.string().max(2000).optional(), example: z.string().max(2000).optional(),
      notes: z.string().max(4000).optional(), forms: z.array(z.string().min(1).max(120)).max(20).optional(),
      contexts: z.array(z.string().min(1).max(40)).max(12).optional(), tags: z.array(z.string().min(1).max(40)).max(20).optional(),
      sourceExcerpt: z.string().max(4000).optional(),
    },
    async (args, eloq) => eloq.addTerm(args));

  tool('update_term',
    'Change a word\'s fields. Only the fields given change.',
    {
      term: z.string().describe('the word, or its id'), text: z.string().min(1).max(120).optional(),
      overused: z.boolean().optional(), target: z.boolean().optional(), meaning: z.string().max(2000).optional(),
      nuance: z.string().max(2000).optional(), whenNotToUse: z.string().max(2000).optional(),
      example: z.string().max(2000).optional(), notes: z.string().max(4000).optional(),
      forms: z.array(z.string().min(1).max(120)).max(20).optional(),
      contexts: z.array(z.string().min(1).max(40)).max(12).optional(), tags: z.array(z.string().min(1).max(40)).max(20).optional(),
    },
    async ({ term, ...patch }, eloq) => eloq.updateTerm(term, patch));

  tool('delete_term',
    'Delete a word and every link to or from it. Usage history stays.',
    { term: z.string().describe('the word, or its id') },
    async ({ term }, eloq) => ({ deleted: brief(await eloq.removeTerm(term)) }), { destructive: true });

  tool('link_terms',
    'Link an overused word to a target word to use instead. Defaults to `suggested`, which lands in the Inbox for the person to review; pass `accepted` only when they asked for it.',
    {
      from: z.string().describe('the overused word, or its id'), to: z.string().describe('the target word, or its id'),
      status: status.default('suggested'), confidence: z.number().int().min(0).max(100).default(70),
      rationale: z.string().max(2000).optional(), useWhen: z.string().max(2000).optional(),
      caution: z.string().max(2000).optional(), example: z.string().max(2000).optional(),
    },
    async (args, eloq) => eloq.link(args));

  tool('set_link_status',
    'Accept, dismiss or re-suggest a link. A dismissed link stays, so it is not suggested again.',
    { link: z.string().describe('the link id, or "from -> to"'), status },
    async ({ link, status: s }, eloq) => eloq.setLinkStatus(link, s));

  tool('update_link',
    'Change a link\'s explanation. Only the fields given change.',
    { link: z.string().describe('the link id, or "from -> to"'), rationale: z.string().max(2000).optional(),
      useWhen: z.string().max(2000).optional(), caution: z.string().max(2000).optional(), example: z.string().max(2000).optional() },
    async ({ link, ...patch }, eloq) => eloq.editLink(link, patch));

  tool('delete_link', 'Delete a link. Prefer set_link_status dismissed, which keeps it from being suggested again.',
    { link: z.string().describe('the link id, or "from -> to"') },
    async ({ link }, eloq) => ({ deleted: await eloq.removeLink(link) }), { destructive: true });

  tool('record_transcript',
    'Count the person\'s overused and target words in something they said or wrote (a voice note, a meeting transcript, a note) and add the counts to their stats for that day. The text itself is not stored. A source already recorded is skipped.',
    {
      sourceKind: z.enum(['obsidian', 'speech', 'letterly']), sourceRef: z.string().min(1).max(400).describe('a stable id: a file path, a Letterly note id'),
      day: day.describe('the day it was said or written'), text: z.string().min(1),
      markdown: z.boolean().default(false).describe('mask code, links and frontmatter before counting'),
    },
    async ({ sourceKind, sourceRef, day: d, text, markdown }, eloq) => {
      const prose = markdown || sourceKind === 'obsidian' ? maskMarkdown(text) : text;
      const contentHash = createHash('sha256').update(text).digest('hex');
      const previous = (await eloq.scans()).find((s) => s.sourceKind === sourceKind && s.sourceRef === sourceRef);
      if (previous) return { recorded: false, reason: previous.contentHash === contentHash ? 'already recorded' : 'already recorded (the text changed since; counts were kept from the first time)' };
      const terms = await eloq.terms();
      const byId = new Map(terms.map((t) => [t.id, t]));
      const counts = new Map<string, { term: Term; kind: 'overused_seen' | 'target_used'; count: number }>();
      for (const m of scan(prose, buildIndex(terms.map((t) => ({ id: t.id, text: t.text, forms: t.forms }))))) {
        for (const id of m.termIds) {
          const t = byId.get(id);
          if (!t) continue;
          const kind = t.overused ? 'overused_seen' : 'target_used';
          const c = counts.get(id) ?? { term: t, kind, count: 0 };
          c.count++;
          counts.set(id, c);
        }
      }
      for (const c of counts.values()) {
        await eloq.addUsage({ term: c.term.id, day: d, channel: sourceKind === 'obsidian' ? 'typing' : 'speech', kind: c.kind, source: sourceKind, count: c.count });
      }
      const words = countWords(prose);
      await eloq.recordScan({ sourceKind, sourceRef, contentHash, day: d, wordCount: words });
      const found = [...counts.values()].sort((a, b) => b.count - a.count);
      return {
        recorded: true, words,
        overused: found.filter((c) => c.kind === 'overused_seen').map((c) => ({ word: c.term.text, count: c.count })),
        targets: found.filter((c) => c.kind === 'target_used').map((c) => ({ word: c.term.text, count: c.count })),
      };
    });

  tool('get_stats',
    'How often each word was said or typed since a day: per word, overused and target counts, and per 1,000 words of recorded speech.',
    { since: day, channel: z.enum(['all', 'typing', 'speech']).default('all') },
    async ({ since, channel }, eloq) => {
      const [terms, usage, scans] = await Promise.all([eloq.terms(), eloq.usageSince(since), eloq.scans()]);
      const text = new Map(terms.map((t) => [t.id, t.text]));
      const spokenWords = scans.filter((s) => s.day >= since && s.sourceKind !== 'obsidian').reduce((n, s) => n + s.wordCount, 0);
      const per = new Map<string, { word: string; overused_seen: number; target_used: number; swapped: number; kept: number }>();
      for (const u of usage) {
        if (channel !== 'all' && u.channel !== channel) continue;
        const row = per.get(u.term) ?? { word: text.get(u.term) ?? '(deleted word)', overused_seen: 0, target_used: 0, swapped: 0, kept: 0 };
        row[u.kind as 'overused_seen'] = (row[u.kind as 'overused_seen'] ?? 0) + u.count;
        per.set(u.term, row);
      }
      const rows = [...per.values()].sort((a, b) => (b.overused_seen + b.target_used) - (a.overused_seen + a.target_used));
      return {
        since, spokenWords,
        words: rows.map((r) => ({ ...r, overusedPer1000: spokenWords ? Math.round((r.overused_seen / spokenWords) * 10000) / 10 : null })),
      };
    }, { readOnly: true });
}
