import { expect, test } from 'bun:test';
import { maskMarkdown } from './markdown.ts';
import { buildIndex, scan } from './matcher.ts';
import { countWords } from './tokenize.ts';

// a small seeded generator so every run scans the same text
function random(seed: number): () => number {
  let state = seed;
  return () => {
    state = (state * 1664525 + 1013904223) % 4294967296;
    return state / 4294967296;
  };
}

const LETTERS = 'abcdefghijklmnopqrstuvwxyz';

function word(next: () => number): string {
  const length = 2 + Math.floor(next() * 8);
  let out = '';
  for (let i = 0; i < length; i += 1) out += LETTERS[Math.floor(next() * LETTERS.length)];
  return out;
}

test('200 terms over a 50,000 word text in well under 100 ms', () => {
  const next = random(42);
  const vocabulary = Array.from({ length: 3000 }, () => word(next));
  const terms = Array.from({ length: 200 }, (_, i) => {
    // three in four terms are single words, the rest are two- to four-word phrases
    const words = i % 4 === 0 ? 2 + (i % 3) : 1;
    const text = Array.from({ length: words }, () => vocabulary[Math.floor(next() * 600)]).join(' ');
    return { id: `t${i}`, text };
  });
  const separators = [' ', ' ', ' ', ' ', ', ', '. ', '\n', ' \u2014 '];
  const parts: string[] = [];
  for (let i = 0; i < 50_000; i += 1) {
    parts.push(vocabulary[Math.floor(next() * vocabulary.length)]);
    parts.push(separators[Math.floor(next() * separators.length)]);
  }
  const text = parts.join('');
  expect(countWords(text)).toBe(50_000);

  const t0 = performance.now();
  const index = buildIndex(terms);
  const t1 = performance.now();
  const matches = scan(text, index);
  const t2 = performance.now();
  // a second scan sees warm code, as a long-running app does
  scan(text, index);
  const t3 = performance.now();
  const masked = maskMarkdown(text);
  const t4 = performance.now();

  console.log(
    `buildIndex ${(t1 - t0).toFixed(1)} ms (${index.forms.size} forms), ` +
      `scan ${(t2 - t1).toFixed(1)} ms cold / ${(t3 - t2).toFixed(1)} ms warm (${matches.length} matches), ` +
      `maskMarkdown ${(t4 - t3).toFixed(1)} ms`,
  );
  expect(matches.length).toBeGreaterThan(1000);
  expect(t2 - t1).toBeLessThan(100);
  expect(masked.length).toBe(text.length);
});
