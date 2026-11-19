// which keys eloq takes from the other app, and which it lets through: the gate
// (apple/Gate.swift) driven with keys as the tap hands them over; and which underlines a key
// leaves on the screen (apple/Underlines.swift). run with `bun test/keys.ts`.
import { spawnSync } from 'node:child_process';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

const dir = mkdtempSync(join(tmpdir(), 'eloq-typing-keys-'));
try {
  const apple = join(import.meta.dir, '../apple');
  const sources = ['TypingLookup.swift', 'AX.swift', 'Layout.swift', 'Underlines.swift', 'Gate.swift'].map((file) => join(apple, file));
  const built = spawnSync('swiftc', ['-O', ...sources, join(import.meta.dir, 'keys/main.swift'), '-o', join(dir, 'keys')], { encoding: 'utf8' });
  if (built.status !== 0) throw new Error(built.stderr);
  const ran = spawnSync(join(dir, 'keys'), [], { encoding: 'utf8' });
  process.stdout.write(ran.stdout + ran.stderr);
  process.exit(ran.status ?? 1);
} finally {
  rmSync(dir, { recursive: true, force: true });
}
