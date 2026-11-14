import { describe, expect, test } from 'bun:test';
import { buildIndex, scan } from './matcher.ts';
import { lookupTyped, tableForTyping, type TypingTable } from './typing.ts';

const terms = [
  { id: 'bunch', text: 'a bunch of' },
  { id: 'abunch', text: 'a bunch' },
  { id: 'interesting', text: 'interesting' },
  { id: 'stop', text: 'stop' },
  { id: 'try', text: 'try' },
  { id: 'cant', text: "can't stand" },
  { id: 'wk', text: 'well-known' },
  { id: 'eg', text: 'e.g.' },
  { id: 'ctor', text: 'constructor' },
  { id: 'proto', text: '__proto__' },
];

// the table as swift receives it
function shipped(): TypingTable {
  return JSON.parse(JSON.stringify(tableForTyping(buildIndex(terms))));
}

describe('tableForTyping', () => {
  test('is plain json with every form', () => {
    const table = shipped();
    expect(table.version).toBe(1);
    expect(table.maxWords).toBe(3);
    expect(table.forms['a bunch of']).toEqual(['bunch']);
    expect(table.forms.stopped).toEqual(['stop']);
    expect(table.forms.tried).toEqual(['try']);
    expect(table.forms.constructor).toEqual(['ctor']);
    expect(Object.keys(table.forms).length).toBe(buildIndex(terms).forms.size);
  });

  test('the last words of a typed sentence give the same ids as scan', () => {
    const index = buildIndex(terms);
    const table = shipped();
    const sentences = [
      'I picked a bunch of',
      'I picked A BUNCH',
      'that was\nreally interesting',
      'that was really Interesting.',
      'we stopped',
      'she tries',
      'I can’t  stand',
      "it's well-known",
      'many tools, e.g.',
      'a new constructor',
      'what about the uninteresting',
      'hello there',
      '',
    ];
    for (const sentence of sentences) {
      const hit = lookupTyped(table, sentence);
      const matches = scan(sentence, index);
      const last = matches[matches.length - 1];
      const endsInMatch = last !== undefined && sentence.slice(last.end).trim().replace(/[.,!?]/g, '') === '';
      if (endsInMatch) {
        expect(hit).not.toBeNull();
        expect(hit!.termIds).toEqual(last.termIds);
        expect(hit!.form).toBe(last.form);
        expect([hit!.start, hit!.end]).toEqual([last.start, last.end]);
      } else {
        expect(hit).toBeNull();
      }
    }
  });

  test('typed lookup reads only the words before the cursor', () => {
    const table = shipped();
    expect(lookupTyped(table, 'a bunch of')!.termIds).toEqual(['bunch']);
    expect(lookupTyped(table, 'a bunch of grapes')).toBeNull();
    expect(lookupTyped(table, 'the prototype')).toBeNull();
    expect(lookupTyped(table, 'it is __proto__')).toBeNull();
  });

  test('a key must have as many words as were taken', () => {
    const table = shipped();
    // "well", en dash, "known" is two typed words but normalizes to a one-word form
    expect(lookupTyped(table, 'a well\u2013known')).toBeNull();
    expect(lookupTyped(table, 'a well-known')!.termIds).toEqual(['wk']);
  });
});
