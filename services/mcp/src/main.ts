#!/usr/bin/env bun
// eloq-mcp: `eloq-mcp login` once, then an mcp client runs `eloq-mcp` over stdio.
// ELOQ_URL names the eloq (snapback) server; it defaults to a local development server.
import { McpServer } from '@modelcontextprotocol/server';
import { StdioServerTransport } from '@modelcontextprotocol/server/stdio';
import { Eloq, EloqError } from './eloq.ts';
import { currentSession, signIn, signOut } from './session.ts';
import { registerTools } from './tools.ts';

const url = (process.env.ELOQ_URL ?? 'http://127.0.0.1:4420').replace(/\/+$/, '');

async function prompt(question: string, hidden = false): Promise<string> {
  process.stderr.write(question);
  if (hidden && process.stdin.isTTY) process.stdin.setRawMode(true);
  let answer = '';
  for await (const chunk of process.stdin) {
    const s = String(chunk);
    if (hidden) {
      for (const ch of s) {
        if (ch === '\r' || ch === '\n') { process.stdin.setRawMode?.(false); process.stderr.write('\n'); return answer; }
        if (ch === '\u0003') process.exit(130);
        if (ch === '\u007f') answer = answer.slice(0, -1); else answer += ch;
      }
    } else {
      answer += s;
      if (answer.includes('\n')) return answer.split('\n')[0]!.trim();
    }
  }
  return answer.trim();
}

const command = process.argv[2];
if (command === 'login') {
  const email = process.env.ELOQ_EMAIL ?? await prompt('Eloq email: ');
  const password = process.env.ELOQ_PASSWORD ?? await prompt('Password: ', true);
  const session = await signIn(url, email, password);
  process.stderr.write(`signed in to ${url} as ${session.principal}\n`);
  process.exit(0);
} else if (command === 'logout') {
  await signOut(url);
  process.stderr.write(`signed out of ${url}\n`);
  process.exit(0);
} else if (command && command !== 'serve') {
  process.stderr.write('usage: eloq-mcp [serve | login | logout]   (ELOQ_URL picks the server)\n');
  process.exit(2);
}

const server = new McpServer({ name: 'eloq', version: '0.1.0' }, {
  instructions: 'Eloq keeps the words a person overuses, the words they want to use more (targets), and links "use this target instead of that overused word". ' +
    'Suggest new links with link_terms (status suggested): they wait in the app\'s Inbox for the person. Count what they said with record_transcript.',
});
registerTools(server, async () => {
  const session = await currentSession(url);
  if (!session) throw new EloqError('E_AUTH', `not signed in to ${url}: run \`eloq-mcp login\``);
  return new Eloq(url, session);
});
await server.connect(new StdioServerTransport());
