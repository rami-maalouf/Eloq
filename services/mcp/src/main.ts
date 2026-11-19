#!/usr/bin/env bun
// eloq-mcp: `eloq-mcp login` once, then an mcp client runs `eloq-mcp` over stdio.
// ELOQ_URL names the eloq (snapback) server; it defaults to a local development server.
import { McpServer } from '@modelcontextprotocol/server';
import { StdioServerTransport } from '@modelcontextprotocol/server/stdio';
import { Eloq, EloqError } from './eloq.ts';
import { currentSession, signIn, signOut } from './session.ts';
import { registerTools } from './tools.ts';

const url = (process.env.ELOQ_URL ?? 'http://127.0.0.1:4420').replace(/\/+$/, '');

// typed input not yet consumed by a prompt (a paste can carry both lines at once).
let pending = '';

// one chunk from stdin, or null at its end. listeners, not `for await`: leaving a
// for-await loop early destroys stdin, and the next prompt then throws AbortError.
function nextChunk(): Promise<string | null> {
  const stdin = process.stdin;
  if (stdin.readableEnded) return Promise.resolve(null);
  return new Promise(resolve => {
    const done = (value: string | null) => {
      stdin.off('data', onData);
      stdin.off('end', onEnd);
      stdin.pause();
      resolve(value);
    };
    const onData = (chunk: Buffer | string) => done(String(chunk));
    const onEnd = () => done(null);
    stdin.on('data', onData);
    stdin.once('end', onEnd);
    stdin.resume();
  });
}

async function prompt(question: string, hidden = false): Promise<string> {
  process.stderr.write(question);
  const raw = hidden && process.stdin.isTTY;
  if (raw) process.stdin.setRawMode(true);
  try {
    let answer = '';
    for (;;) {
      while (pending) {
        const ch = pending[0]!;
        pending = pending.slice(1);
        if (ch === '\r' || ch === '\n') {
          if (ch === '\r' && pending[0] === '\n') pending = pending.slice(1);
          if (hidden) process.stderr.write('\n');
          // a password keeps its spaces; an email does not.
          return hidden ? answer : answer.trim();
        }
        if (ch === '\u0003') process.exit(130);
        if (ch === '\u007f' || ch === '\b') answer = answer.slice(0, -1); else answer += ch;
      }
      const chunk = await nextChunk();
      if (chunk === null) return hidden ? answer : answer.trim();
      pending += chunk;
    }
  } finally {
    if (raw) process.stdin.setRawMode(false);
  }
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
