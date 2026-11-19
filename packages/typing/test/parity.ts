// the swift lookup (apple/TypingLookup.swift) answers every typed text exactly as the
// typescript reference (packages/matcher lookupTyped): run with `bun test/parity.ts`.
import { spawnSync } from 'node:child_process';
import { mkdtempSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { buildIndex, lookupTyped, scan, tableForTyping } from '../../matcher/src/index.ts';

const terms = [
  'interesting', 'a bunch of', 'basically', "can't stand", 'state-of-the-art', 'really', 'café', 'kind of',
  'stop', 'try', 'make', 'box', 'well-known', 'of course', 'like', 'just', 'thing', 'naïve', 'rock \'n\' roll',
].map((text, i) => ({ id: `t${i}`, text }));
const table = tableForTyping(buildIndex(terms));
// the underlines scan a whole text for overused and target words: every third word is a target here
const isTarget = (id: string) => Number(id.slice(1)) % 3 === 0;
const all = buildIndex(terms);
const kindOf = (ids: string[]) => (ids.some((id) => !isTarget(id)) ? 'overused' : 'target');
const overusedForms = [...all.forms].filter(([, e]) => kindOf(e.termIds) === 'overused').map(([f]) => f);
const targetForms = [...all.forms].filter(([, e]) => kindOf(e.termIds) === 'target').map(([f]) => f);

// deterministic cases: real sentences, then random mixes of words, joiners and separators
const fixed = [
  'That was interesting', 'that was Interesting', 'a bunch of', 'A  bunch\nof', 'I really', 'I can’t stand',
  'I can’t   stand', 'state‑of‑the‑art', 'stopped', 'stopping', 'tries', 'tried', 'making', 'boxes',
  'uninteresting', 'interestingly', 'well-known', 'well–known', 'of course', 'a bunch of course', 'café',
  'naïve', "rock 'n' roll", 'just', 'things', 'liked', '', '   ', '123', 'basically,', '"basically', 'kind  of',
];
let seed = 7;
const rand = (n: number) => ((seed = (seed * 1103515245 + 12345) % 2147483648), seed % n);
const pieces = ['interesting', 'a', 'bunch', 'of', 'basically', "can't", 'can’t', 'stand', 'state', '-', 'of', 'the',
  'art', 'really', 'café', 'kind', 'stop', 'stopped', 'tries', 'box', 'boxes', 'well', 'known', 'course', 'like',
  'just', 'thing', 'naïve', 'rock', "'n'", 'roll', 'x', 'Interesting', 'REALLY'];
const seps = [' ', '  ', '\n', ', ', '. ', '-', '’', "'", '\t', ' — ', '', ' '];
const random = Array.from({ length: 2000 }, () => {
  let s = '';
  for (let i = 0, n = 1 + rand(6); i < n; i++) s += pieces[rand(pieces.length)] + (i < n - 1 ? seps[rand(seps.length)] : '');
  return s;
});
const cases = [...fixed, ...random];
const expected = cases.map((c) => {
  const hit = lookupTyped(table, c);
  return hit ? { ids: hit.termIds, text: c.slice(hit.start, hit.end) } : null;
});

const expectedScans = cases.map((c) => scan(c, all).map((m) => ({ start: m.start, end: m.end, kind: kindOf(m.termIds) })));

const dir = mkdtempSync(join(tmpdir(), 'eloq-typing-parity-'));
try {
  writeFileSync(join(dir, 'input.json'), JSON.stringify({ forms: table.forms, maxWords: table.maxWords, cases, overusedForms, targetForms }));
  writeFileSync(join(dir, 'main.swift'), `
import Foundation
let data = try! Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
let input = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
let lookup = TypingLookup(forms: input["forms"] as! [String: [String]], maxWords: input["maxWords"] as! Int)
let out: [Any] = (input["cases"] as! [String]).map { c in
  guard let hit = lookup.lookup(c) else { return NSNull() }
  return ["ids": hit.termIds, "text": hit.text] as [String: Any]
}
let scanner = TextScan(overused: input["overusedForms"] as! [String], targets: input["targetForms"] as! [String])
let scans: [Any] = (input["cases"] as! [String]).map { c in
  scanner.scan(c).map { ["start": $0.start, "end": $0.end, "kind": $0.kind.rawValue] as [String: Any] }
}
FileHandle.standardOutput.write(try! JSONSerialization.data(withJSONObject: ["lookups": out, "scans": scans]))
`);
  const built = spawnSync('swiftc', ['-O', join(import.meta.dir, '../apple/TypingLookup.swift'), join(dir, 'main.swift'), '-o', join(dir, 'parity')], { encoding: 'utf8' });
  if (built.status !== 0) throw new Error(built.stderr);
  const ran = spawnSync(join(dir, 'parity'), [join(dir, 'input.json')], { encoding: 'utf8', maxBuffer: 64 << 20 });
  if (ran.status !== 0) throw new Error(ran.stderr);
  const answer = JSON.parse(ran.stdout) as { lookups: Array<{ ids: string[]; text: string } | null>; scans: Array<Array<{ start: number; end: number; kind: string }>> };
  const actual = answer.lookups;
  let failures = 0;
  cases.forEach((c, i) => {
    const norm = (h: { ids: string[]; text: string } | null) => JSON.stringify(h && { ids: h.ids, text: h.text });
    const a = norm(actual[i]), e = norm(expected[i]);
    if (a !== e && failures++ < 15) console.log(`mismatch ${JSON.stringify(c)}\n  swift ${a}\n  ts    ${e}`);
  });
  let marks = 0;
  cases.forEach((c, i) => {
    const order = (list: Array<{ start: number; end: number; kind: string }>) => JSON.stringify(list.map((m) => [m.start, m.end, m.kind]));
    const a = order(answer.scans[i]), e = order(expectedScans[i]);
    marks += expectedScans[i].length;
    if (a !== e && failures++ < 15) console.log(`scan mismatch ${JSON.stringify(c)}\n  swift ${a}\n  ts    ${e}`);
  });
  const hits = expected.filter(Boolean).length;
  console.log(`${cases.length} cases, ${hits} hits, ${marks} scan marks: ${failures === 0 ? 'swift matches the typescript reference' : `${failures} mismatches`}`);
  process.exit(failures === 0 ? 0 : 1);
} finally {
  rmSync(dir, { recursive: true, force: true });
}
