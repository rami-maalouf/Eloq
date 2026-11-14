import { expect, test } from 'bun:test';
import { normalize } from './normalize.ts';

test('case, spacing and apostrophes collapse to one identity', () => {
  expect(normalize("  Can’t   Stand ")).toBe("can't stand");
  expect(normalize('Interesting.')).toBe('interesting');
  expect(normalize('"a bunch of"')).toBe('a bunch of');
  expect(normalize('state‑of‑the‑art')).toBe('state-of-the-art');
});

test('inner punctuation is kept', () => {
  expect(normalize("rock 'n' roll")).toBe("rock 'n' roll");
  expect(normalize('e.g.')).toBe('e.g');
});
