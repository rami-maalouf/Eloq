import { describe, expect, test } from 'bun:test';
import { buildIndex, scan, type Match, type Term } from './matcher.ts';
import { countWords, tokenize } from './tokenize.ts';

function found(text: string, terms: Term[]): Array<[string, string[]]> {
  return scan(text, buildIndex(terms)).map((m) => [text.slice(m.start, m.end), m.termIds]);
}

describe('tokenize and countWords', () => {
  test('hyphens and apostrophes inside a word join it', () => {
    const text = "It's a well-known, rock 'n' roll thing\u2014really.";
    expect(tokenize(text).map((t) => text.slice(t.start, t.end))).toEqual([
      "It's", 'a', 'well-known', 'rock', 'n', 'roll', 'thing', 'really',
    ]);
  });

  test('edge apostrophes and hyphens are not part of a word', () => {
    const text = "the dogs' -ish 'quoted'";
    expect(tokenize(text).map((t) => text.slice(t.start, t.end))).toEqual(['the', 'dogs', 'ish', 'quoted']);
  });

  test('the character loop agrees with the documented regular expression', () => {
    const reference = /[\p{L}\p{M}\p{N}]+(?:['‘’ʼ`´\-‐\u2011][\p{L}\p{M}\p{N}]+)*/gu;
    const alphabet = ['a', 'Z', '7', 'é', 'e\u0301', 'ж', '東', '٣', '𝒜', '😀', '\ud800', "'", '’', 'ʼ', '`', '´', '-', '‐', '\u2011', '\u2013', '\u2014', ' ', '\n', '.', ',', '_', '#'];
    let state = 7;
    for (let round = 0; round < 2000; round += 1) {
      let text = '';
      const length = round % 40;
      for (let i = 0; i < length; i += 1) {
        state = (state * 1103515245 + 12345) % 2147483648;
        text += alphabet[state % alphabet.length];
      }
      const expected = [...text.matchAll(reference)].map((m) => [m.index, m.index + m[0].length]);
      expect(tokenize(text).map((t) => [t.start, t.end])).toEqual(expected);
      expect(countWords(text)).toBe(expected.length);
    }
  });

  test('letters of any script, marks and digits', () => {
    expect(countWords('café naïve Ελλάδα 東京 3rd 😀 e\u0301té')).toBe(6);
    expect(countWords('')).toBe(0);
    expect(countWords('  ... !!! ')).toBe(0);
  });
});

describe('scan', () => {
  test('inflections of a single word', () => {
    const terms = [{ id: 'stop', text: 'stop' }, { id: 'try', text: 'try' }, { id: 'make', text: 'make' }, { id: 'box', text: 'box' }];
    const text = 'He stopped, then kept stopping. She tries and tried. Making boxes stops nothing.';
    expect(found(text, terms)).toEqual([
      ['stopped', ['stop']],
      ['stopping', ['stop']],
      ['tries', ['try']],
      ['tried', ['try']],
      ['Making', ['make']],
      ['boxes', ['box']],
      ['stops', ['stop']],
    ]);
  });

  test('a phrase matches across any whitespace, newlines too', () => {
    const terms = [{ id: 'bunch', text: 'a bunch of' }];
    expect(found('I have A  bunch\nof\tideas', terms)).toEqual([['A  bunch\nof', ['bunch']]]);
    expect(found('a\r\n\r\nbunch \u00a0of', terms)).toEqual([['a\r\n\r\nbunch \u00a0of', ['bunch']]]);
  });

  test('punctuation between words breaks a phrase', () => {
    const terms = [{ id: 'bunch', text: 'a bunch of' }];
    expect(found('a bunch, of', terms)).toEqual([]);
    expect(found('a bunch. Of course', terms)).toEqual([]);
  });

  test('inner punctuation of a phrase must be in the text', () => {
    const terms = [{ id: 'wa', text: 'Well, actually' }, { id: 'eg', text: 'e.g.' }];
    expect(found('Well, actually, e.g. this', terms)).toEqual([
      ['Well, actually', ['wa']],
      ['e.g', ['eg']],
    ]);
    expect(found('well actually', terms)).toEqual([]);
  });

  test('the longest match wins', () => {
    const terms = [{ id: 'short', text: 'a bunch' }, { id: 'long', text: 'a bunch of' }];
    expect(found('a bunch of grapes and a bunch more', terms)).toEqual([
      ['a bunch of', ['long']],
      ['a bunch', ['short']],
    ]);
  });

  test('a tie keeps every term', () => {
    const terms = [{ id: 'stop', text: 'stop' }, { id: 'stops', text: 'stops' }];
    expect(found('it stops', terms)).toEqual([['stops', ['stop', 'stops']]]);
  });

  test('overlapping candidates: left to right, then longest, never overlapping', () => {
    const terms = [{ id: 'bunch', text: 'a bunch of' }, { id: 'course', text: 'of course' }, { id: 'people', text: 'of people' }];
    expect(found('a bunch of people, of course', terms)).toEqual([
      ['a bunch of', ['bunch']],
      ['of course', ['course']],
    ]);
  });

  test('no match inside a longer word', () => {
    const terms = [{ id: 'i', text: 'interesting' }];
    expect(found('uninteresting interestingly interesting-ly', terms)).toEqual([]);
    expect(found('Interesting!', terms)).toEqual([['Interesting', ['i']]]);
  });

  test('a hyphen-joined word is one word', () => {
    const terms = [{ id: 'well', text: 'well' }, { id: 'known', text: 'known' }, { id: 'wk', text: 'well-known' }];
    expect(found('a well-known fact, well known', terms)).toEqual([
      ['well-known', ['wk']],
      ['well', ['well']],
      ['known', ['known']],
    ]);
    // a non-breaking hyphen is a hyphen; an em dash separates
    expect(found('well\u2011known well\u2014known', terms)).toEqual([
      ['well\u2011known', ['wk']],
      ['well', ['well']],
      ['known', ['known']],
    ]);
  });

  test('curly apostrophes match straight ones both ways', () => {
    const straight = [{ id: 'cs', text: "can't stand" }];
    expect(found('I can’t stand it', straight)).toEqual([['can’t stand', ['cs']]]);
    const curly = [{ id: 'cs', text: 'can’t stand' }];
    expect(found("I CAN'T STAND it", curly)).toEqual([["CAN'T STAND", ['cs']]]);
  });

  test('offsets point into the original text after emoji and accents', () => {
    const terms = [{ id: 'i', text: 'interesting' }, { id: 'c', text: 'café' }];
    const text = '😀👍🏽 Ça déjà vu, café\u0301 cafe\u0301 is 🤔 interesting';
    const matches = scan(text, buildIndex(terms));
    expect(matches.map((m) => text.slice(m.start, m.end))).toEqual(['cafe\u0301', 'interesting']);
    expect(matches[1].start).toBe(text.indexOf('interesting'));
    expect(matches[0].form).toBe('café');
  });

  test('the match reports the normalized form', () => {
    const matches: Match[] = scan('He STOPPED.', buildIndex([{ id: 's', text: 'stop' }]));
    expect(matches).toEqual([{ termIds: ['s'], form: 'stopped', start: 3, end: 10 }]);
  });

  test('explicit forms match, inflections of phrases do not', () => {
    const terms = [{ id: 'ms', text: 'make sense', forms: ['made sense'] }];
    expect(found('it made sense, it makes sense', terms)).toEqual([['made sense', ['ms']]]);
  });

  test('empty index, empty text and symbol-only terms', () => {
    expect(scan('anything at all', buildIndex([]))).toEqual([]);
    expect(scan('', buildIndex([{ id: 'a', text: 'a' }]))).toEqual([]);
    const index = buildIndex([{ id: 'c', text: 'c++' }, { id: 'e', text: '...' }]);
    expect(index.forms.size).toBe(0);
    expect(scan('c++ ...', index)).toEqual([]);
  });

  test('buildIndex keeps word counts and the longest phrase', () => {
    const index = buildIndex([{ id: 'a', text: 'a bunch of' }, { id: 'b', text: 'well-known' }]);
    expect(index.maxWords).toBe(3);
    expect(index.forms.get('a bunch of')).toEqual({ termIds: ['a'], words: 3 });
    expect(index.forms.get('well-known')).toEqual({ termIds: ['b'], words: 1 });
  });

  test('a phrase matches only with its own word count', () => {
    // the en dash separates "well" and "known" in the text but becomes a hyphen
    // under normalize, so the two words must not match the one-word form
    // ("a bunch of" makes scan try three-word windows starting at "a")
    const terms = [{ id: 'wk', text: 'a well-known' }, { id: 'b', text: 'a bunch of' }];
    expect(found('a well\u2013known thing', terms)).toEqual([]);
    expect(found('a well-known thing', terms)).toEqual([['a well-known', ['wk']]]);
  });
});
