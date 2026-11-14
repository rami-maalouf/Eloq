// the real thing: a snapback dev server (`bun run backend:dev` at the repo root), this server over
// stdio, and the official mcp client calling every tool.
import { afterAll, beforeAll, expect, test } from 'bun:test';
import { mkdtemp, rm, writeFile, mkdir } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { Client } from '@modelcontextprotocol/client';
import { StdioClientTransport } from '@modelcontextprotocol/client/stdio';
import { signup } from 'snapback4/auth';

const url = process.env.ELOQ_TEST_URL ?? 'http://127.0.0.1:4420';
let dir = '';
let client: Client;

type Reply = { isError?: boolean; content: Array<{ type: string; text: string }> };
async function call(name: string, args: Record<string, unknown> = {}): Promise<{ error?: string; value?: any }> {
  const r = await client.callTool({ name, arguments: args }) as Reply;
  const text = r.content[0]?.text ?? '';
  return r.isError ? { error: text } : { value: JSON.parse(text) };
}

beforeAll(async () => {
  const reachable = await fetch(`${url}/auth/config`).then((r) => r.ok, () => false);
  if (!reachable) throw new Error(`no snapback server at ${url}: run \`bun run backend:dev\` at the repo root`);
  dir = await mkdtemp(join(tmpdir(), 'eloq-mcp-'));
  const signed = await signup(url, `mcp-${Date.now()}@example.com`, 'correct horse battery staple');
  if (!signed.ok) throw new Error(signed.why.code);
  const name = url.replace(/^https?:\/\//, '').replace(/[^a-z0-9.-]/gi, '-').toLowerCase();
  await mkdir(dir, { recursive: true });
  await writeFile(join(dir, `session-${name}.json`), JSON.stringify(signed.session), { mode: 0o600 });
  client = new Client({ name: 'eloq-test', version: '0' });
  await client.connect(new StdioClientTransport({
    command: process.execPath, args: [join(import.meta.dir, 'main.ts')],
    env: { ...process.env, ELOQ_URL: url, ELOQ_CONFIG_DIR: dir } as Record<string, string>,
  }));
});

afterAll(async () => {
  await client?.close();
  if (dir) await rm(dir, { recursive: true, force: true });
});

test('lists its tools', async () => {
  const { tools } = await client.listTools();
  expect(tools.map((t) => t.name).sort()).toEqual([
    'add_term', 'delete_link', 'delete_term', 'get_stats', 'get_term', 'link_terms', 'list_links',
    'record_transcript', 'search_terms', 'set_link_status', 'update_link', 'update_term',
  ]);
});

test('an agent adds words, suggests a move, and the person can accept it', async () => {
  expect((await call('add_term', { text: 'Interesting', overused: true, target: false, meaning: 'arousing curiosity' })).value.normalized).toBe('interesting');
  expect((await call('add_term', { text: 'compelling', overused: false, target: true })).value.target).toBe(true);
  expect((await call('add_term', { text: 'interesting ', overused: true, target: false })).error).toStartWith('TERM_EXISTS');
  expect((await call('add_term', { text: 'nothing', overused: false, target: false })).error).toStartWith('E_INPUT');

  const link = (await call('link_terms', { from: 'interesting', to: 'Compelling', useWhen: 'a point holds attention' })).value;
  expect(link.status).toBe('suggested');
  expect(link.origin).toBe('agent');
  expect((await call('list_links', { status: 'suggested' })).value.total).toBe(1);

  expect((await call('set_link_status', { link: 'interesting -> compelling', status: 'accepted' })).value.status).toBe('accepted');
  const t = (await call('get_term', { term: 'INTERESTING' })).value;
  expect(t.useInstead.map((l: { word: string }) => l.word)).toEqual(['compelling']);
  expect((await call('get_term', { term: 'compelling' })).value.replaces[0].word).toBe('Interesting');

  expect((await call('update_term', { term: 'interesting', nuance: 'vague praise' })).value.nuance).toBe('vague praise');
  expect((await call('search_terms', { role: 'target' })).value.terms.map((x: { text: string }) => x.text)).toEqual(['compelling']);
});

test('a transcript is counted once, with no text stored', async () => {
  await call('add_term', { text: 'a bunch of', overused: true, target: false });
  const text = 'That was interesting. Really interesting,\nand a bunch of\npeople found it compelling. Interestingly, not all.';
  const first = (await call('record_transcript', { sourceKind: 'speech', sourceRef: 'test:1', day: '2026-11-14', text })).value;
  expect(first.recorded).toBe(true);
  expect(first.overused).toEqual([{ word: 'Interesting', count: 2 }, { word: 'a bunch of', count: 1 }]);
  expect(first.targets).toEqual([{ word: 'compelling', count: 1 }]);
  expect((await call('record_transcript', { sourceKind: 'speech', sourceRef: 'test:1', day: '2026-11-14', text })).value.recorded).toBe(false);

  const stats = (await call('get_stats', { since: '2026-11-01' })).value;
  expect(stats.spokenWords).toBe(first.words);
  const row = stats.words.find((w: { word: string }) => w.word === 'Interesting');
  expect(row.overused_seen).toBe(2);
});

test('deleting a word takes its links', async () => {
  expect((await call('delete_term', { term: 'compelling' })).value.deleted.text).toBe('compelling');
  expect((await call('list_links', { status: 'all' })).value.total).toBe(0);
  expect((await call('get_term', { term: 'compelling' })).error).toStartWith('NOT_FOUND');
});
