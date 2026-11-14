import type { MatchIndex } from './matcher.ts';
import { normalize } from './normalize.ts';
import { countWords, tokenize } from './tokenize.ts';

// the lookup table for the swift typing module, which checks the words just typed
// on every word boundary without running the matcher.
//
// table: { version: 1, maxWords, forms: { [normalized form]: termIds } }
//
// lookup rule (lookupTyped below is the reference; swift ports it):
// 1. words: split the typed text before the cursor into words with the word rule
//    of tokenize.ts: a word is a run of unicode letters (L), marks (M) and digits
//    (N); one of ' ‘ ’ ʼ ` ´ - U+2010 U+2011 between two such runs joins them into
//    one word. everything else separates words. let n be the number of words.
// 2. for k from min(maxWords, n) down to 1: take the original text from the start
//    of word n-k+1 to the end of word n (the last k words and what is between
//    them), normalize it, and look it up in forms. it is a hit when the key exists
//    and the key itself has exactly k words by the rule of step 1. the first hit
//    (the longest) is the answer; no hit means no term.
// 3. normalize must equal normalize.ts exactly, in this order:
//    a. unicode nfc (swift: precomposedStringWithCanonicalMapping)
//    b. each of ‘ ’ ʼ ` ´ becomes '
//    c. each of U+2010 to U+2015 becomes -
//    d. lowercase with the default unicode mapping (swift: lowercased())
//    e. each run of whitespace becomes one space. whitespace is javascript \s:
//       U+0009 to U+000D, U+0020, U+00A0, U+1680, U+2000 to U+200A, U+2028,
//       U+2029, U+202F, U+205F, U+3000, U+FEFF (not U+0085)
//    f. strip from both ends any run of whitespace and " ' “ ” « » ( ) [ ] { } . , ; : ! ?
//    the key in step 2 starts and ends inside a word, so f never changes it.
//
// the hit uses only the words before the cursor, so it can differ from scan() on
// the whole text, which matches left to right: with the terms "a bunch of" and
// "of course", typing "a bunch of course" gives "of course" here but "a bunch of"
// in scan. the typing module should fire only when a word has ended: a hyphen or
// an apostrophe right after a letter may continue the word ("well-", "can'").

export type TypingTable = {
  version: 1;
  maxWords: number;
  forms: Record<string, string[]>;
};

export type TypedHit = {
  termIds: string[];
  form: string;
  words: number;
  start: number;
  end: number;
};

export function tableForTyping(index: MatchIndex): TypingTable {
  // no prototype, so a form like "constructor" or "__proto__" is an ordinary key
  const forms = Object.create(null) as Record<string, string[]>;
  for (const [form, entry] of index.forms) forms[form] = entry.termIds.slice();
  return { version: 1, maxWords: index.maxWords, forms };
}

export function lookupTyped(table: TypingTable, typed: string): TypedHit | null {
  const tokens = tokenize(typed);
  const n = tokens.length;
  for (let k = Math.min(table.maxWords, n); k >= 1; k -= 1) {
    const start = tokens[n - k].start;
    const end = tokens[n - 1].end;
    const form = normalize(typed.slice(start, end));
    // the table may come back from JSON.parse with a normal prototype
    if (!Object.prototype.hasOwnProperty.call(table.forms, form)) continue;
    if (countWords(form) !== k) continue;
    return { termIds: table.forms[form].slice(), form, words: k, start, end };
  }
  return null;
}
