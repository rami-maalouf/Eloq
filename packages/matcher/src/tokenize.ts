// the one word rule. scan, countWords, buildIndex and the typing table all split
// text into words through this, so a term's word count and the text's words agree.
//
// a word is a run of letters, combining marks and digits (unicode categories L, M
// and N). an apostrophe or a hyphen joins two such runs into one word ("can't",
// "well-known", "o'clock"), but never starts or ends a word: in "dogs'" the word is
// "dogs", in "-ish" it is "ish". the joiners are the characters normalize() turns
// into ' (' ‘ ’ ʼ ` ´) and the true hyphens (- U+2010 U+2011). en and em dashes
// separate words, so "interesting\u2014but" (em dash) is two words.
//
// everything else (spaces, punctuation, symbols, emoji) separates words.
// offsets are utf-16 code unit offsets into the original text.
//
// as a regular expression the rule is
//   /[\p{L}\p{M}\p{N}]+(?:['‘’ʼ`´\-‐‑][\p{L}\p{M}\p{N}]+)*/gu
// (the tests check that the code below agrees with it). the code is a character
// loop because hermes is slow with unicode property escapes: on 50,000 words the
// regular expression took 63 ms and this loop takes 27 ms.

export type Token = { start: number; end: number };

const ASCII_WORD = new Uint8Array(128);
for (let c = 48; c <= 57; c += 1) ASCII_WORD[c] = 1;
for (let c = 65; c <= 90; c += 1) ASCII_WORD[c] = 1;
for (let c = 97; c <= 122; c += 1) ASCII_WORD[c] = 1;

const WORD_CHAR = /^[\p{L}\p{M}\p{N}]$/u;
// code point -> is a word character, for everything outside ascii
const seen = new Map<number, boolean>();

// the length in code units (1 or 2) of the word character at i, or 0
function wordCharLength(text: string, i: number): number {
  const code = text.charCodeAt(i);
  if (code < 128) return ASCII_WORD[code];
  let point = code;
  let length = 1;
  if (code >= 0xd800 && code <= 0xdbff && i + 1 < text.length) {
    const low = text.charCodeAt(i + 1);
    if (low >= 0xdc00 && low <= 0xdfff) {
      point = (code - 0xd800) * 0x400 + (low - 0xdc00) + 0x10000;
      length = 2;
    }
  }
  let word = seen.get(point);
  if (word === undefined) {
    word = WORD_CHAR.test(String.fromCodePoint(point));
    seen.set(point, word);
  }
  return word ? length : 0;
}

function isJoiner(code: number): boolean {
  return (
    code === 0x27 || // '
    code === 0x2d || // -
    code === 0x2018 || // ‘
    code === 0x2019 || // ’
    code === 0x02bc || // ʼ
    code === 0x60 || // `
    code === 0xb4 || // ´
    code === 0x2010 || // hyphen
    code === 0x2011 // non-breaking hyphen
  );
}

// the end of the word starting at i, or i when no word starts there
function wordEnd(text: string, i: number): number {
  const n = text.length;
  let end = i;
  for (;;) {
    let length = wordCharLength(text, end);
    while (length > 0) {
      end += length;
      length = end < n ? wordCharLength(text, end) : 0;
    }
    // a joiner continues the word only when a word character follows it
    if (end > i && end + 1 < n && isJoiner(text.charCodeAt(end)) && wordCharLength(text, end + 1) > 0) {
      end += 1;
      continue;
    }
    return end;
  }
}

export function tokenize(text: string): Token[] {
  const tokens: Token[] = [];
  let i = 0;
  while (i < text.length) {
    const end = wordEnd(text, i);
    if (end === i) {
      i += 1;
    } else {
      tokens.push({ start: i, end });
      i = end;
    }
  }
  return tokens;
}

export function countWords(text: string): number {
  let count = 0;
  let i = 0;
  while (i < text.length) {
    const end = wordEnd(text, i);
    if (end === i) {
      i += 1;
    } else {
      count += 1;
      i = end;
    }
  }
  return count;
}
