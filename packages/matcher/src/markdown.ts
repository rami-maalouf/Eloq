// blanks the parts of a markdown note that are not prose, so scan() only sees
// what the writer wrote as sentences. each masked character becomes a space; line
// breaks stay, so the result has the same length and the same lines, and offsets
// from scan() point into the original note.
//
// masked: yaml or toml frontmatter, fenced code, inline code, math ($...$ and
// $$...$$), html and obsidian (%%...%%) comments, html tags (not the text between
// them), wiki links ([[target]] whole, [[target|alias]] keeps the alias, embeds
// ![[file]] whole), images ![alt](url) whole, link destinations ([text](url) and
// [text][ref] keep the text), reference definitions, footnote markers, autolinks
// <...>, bare urls and emails, #tags, task checkboxes and ^block-ids.
// not masked: indented code (4-space indents are usually nested lists in notes)
// and markdown punctuation (# > * _ | -), which the tokenizer skips anyway.
//
// the phases run in order on the partly masked text, so a later phase never sees
// what an earlier one removed: a $ or a [ inside code does not start math or a link.

type Range = [number, number];
type Phase = (text: string) => Range[];

export function maskMarkdown(text: string): string {
  let out = text;
  for (const phase of PHASES) {
    const ranges = phase(out);
    if (ranges.length > 0) out = blank(out, ranges);
  }
  return out;
}

function blank(text: string, ranges: Range[]): string {
  ranges.sort((a, b) => a[0] - b[0]);
  const parts: string[] = [];
  let at = 0;
  for (const [from, to] of ranges) {
    const start = Math.max(at, from);
    if (to <= start) continue;
    const region = text.slice(start, to);
    const spaces = region.indexOf('\n') < 0 && region.indexOf('\r') < 0;
    parts.push(text.slice(at, start), spaces ? ' '.repeat(region.length) : region.replace(NOT_LINE_BREAK, ' '));
    at = to;
  }
  parts.push(text.slice(at));
  return parts.join('');
}

const NOT_LINE_BREAK = /[^\n\r]/g;

function allMatches(text: string, pattern: RegExp, each: (match: RegExpExecArray, ranges: Range[]) => void): Range[] {
  const ranges: Range[] = [];
  pattern.lastIndex = 0;
  let match = pattern.exec(text);
  while (match !== null) {
    if (match[0].length === 0) pattern.lastIndex += 1;
    each(match, ranges);
    match = pattern.exec(text);
  }
  return ranges;
}

function whole(pattern: RegExp): Phase {
  return (text) => allMatches(text, pattern, (m, ranges) => {
    ranges.push([m.index, m.index + m[0].length]);
  });
}

type Line = { start: number; end: number; text: string };

function lines(text: string): Line[] {
  const out: Line[] = [];
  let start = 0;
  while (start <= text.length) {
    let end = text.indexOf('\n', start);
    if (end < 0) end = text.length;
    const content = text.slice(start, end);
    out.push({ start, end, text: content.endsWith('\r') ? content.slice(0, -1) : content });
    start = end + 1;
  }
  return out;
}

// --- block phases

function frontmatter(text: string): Range[] {
  const all = lines(text);
  const open = all[0].text.trimEnd();
  if (open !== '---' && open !== '+++') return [];
  for (let i = 1; i < all.length; i += 1) {
    const line = all[i].text.trimEnd();
    if (line === open || (open === '---' && line === '...')) return [[0, all[i].end]];
  }
  // never closed: a horizontal rule, not frontmatter
  return [];
}

const FENCE_OPEN = /^ {0,3}(`{3,}|~{3,})(.*)$/;
const FENCE_CLOSE = /^ {0,3}(`{3,}|~{3,})[ \t]*$/;

function fences(text: string): Range[] {
  const ranges: Range[] = [];
  let open: { fence: string; start: number } | null = null;
  for (const line of lines(text)) {
    if (open === null) {
      const m = FENCE_OPEN.exec(line.text);
      // a backtick fence's info string cannot contain a backtick
      if (m !== null && !(m[1][0] === '`' && m[2].indexOf('`') >= 0)) open = { fence: m[1], start: line.start };
      continue;
    }
    const m = FENCE_CLOSE.exec(line.text);
    if (m !== null && m[1][0] === open.fence[0] && m[1].length >= open.fence.length) {
      ranges.push([open.start, line.end]);
      open = null;
    }
  }
  // an unclosed fence runs to the end of the note
  if (open !== null) ranges.push([open.start, text.length]);
  return ranges;
}

// --- inline phases

// a code span opens with a run of n backticks and closes with the next run of
// exactly n, within the same paragraph
function inlineCode(text: string): Range[] {
  const ranges: Range[] = [];
  const n = text.length;
  let i = 0;
  while (i < n) {
    if (text[i] !== '`') {
      i += 1;
      continue;
    }
    let j = i;
    while (j < n && text[j] === '`') j += 1;
    if (i > 0 && text[i - 1] === '\\') {
      i = j;
      continue;
    }
    const run = j - i;
    let k = j;
    let close = -1;
    while (k < n) {
      if (text[k] === '`') {
        let m = k;
        while (m < n && text[m] === '`') m += 1;
        if (m - k === run) {
          close = m;
          break;
        }
        k = m;
      } else if (text[k] === '\n' && blankLineAfter(text, k)) {
        break;
      } else {
        k += 1;
      }
    }
    if (close >= 0) {
      ranges.push([i, close]);
      i = close;
    } else {
      i = j;
    }
  }
  return ranges;
}

function blankLineAfter(text: string, newline: number): boolean {
  for (let i = newline + 1; i < text.length; i += 1) {
    const c = text[i];
    if (c === '\n') return true;
    if (c !== ' ' && c !== '\t' && c !== '\r') return false;
  }
  return true;
}

// inline math: no space just inside the dollars and no digit right after the
// closing one, so "costs $5 and $10" stays prose
const INLINE_MATH = /\$[^\s$](?:[^$\n]*[^\s$\\])?\$/g;

function inlineMath(text: string): Range[] {
  return allMatches(text, INLINE_MATH, (m, ranges) => {
    const end = m.index + m[0].length;
    const escaped = m.index > 0 && text[m.index - 1] === '\\';
    const digitAfter = end < text.length && text[end] >= '0' && text[end] <= '9';
    if (escaped || digitAfter) {
      INLINE_MATH.lastIndex = m.index + 1;
      return;
    }
    ranges.push([m.index, end]);
  });
}

const WIKI_LINK = /(!?)\[\[([^\[\]\n]+)\]\]/g;

function wikiLinks(text: string): Range[] {
  return allMatches(text, WIKI_LINK, (m, ranges) => {
    const start = m.index;
    const end = start + m[0].length;
    const pipe = m[2].indexOf('|');
    if (m[1] === '!' || pipe < 0) {
      ranges.push([start, end]);
      return;
    }
    // keep the alias: blank "[[target|" and "]]"
    const aliasStart = start + 2 + pipe + 1;
    ranges.push([start, aliasStart], [end - 2, end]);
  });
}

// the index of the ")" closing the "(" at open, on the same line, or -1
function closingParen(text: string, open: number): number {
  let depth = 0;
  for (let i = open; i < text.length; i += 1) {
    const c = text[i];
    if (c === '\\') {
      i += 1;
    } else if (c === '(') {
      depth += 1;
    } else if (c === ')') {
      depth -= 1;
      if (depth === 0) return i;
    } else if (c === '\n') {
      return -1;
    }
  }
  return -1;
}

const IMAGE = /!\[[^\]\n]*\]\(/g;

function images(text: string): Range[] {
  return allMatches(text, IMAGE, (m, ranges) => {
    const close = closingParen(text, m.index + m[0].length - 1);
    if (close >= 0) ranges.push([m.index, close + 1]);
  });
}

const INLINE_LINK = /\[([^\[\]\n]*)\]\(/g;

function links(text: string): Range[] {
  return allMatches(text, INLINE_LINK, (m, ranges) => {
    const textEnd = m.index + 1 + m[1].length;
    const close = closingParen(text, textEnd + 1);
    if (close < 0) return;
    // keep the link text: blank "[" and "](destination)"
    ranges.push([m.index, m.index + 1], [textEnd, close + 1]);
  });
}

// [text][ref] and [text][] keep the text; footnote markers [^1] go entirely
const REFERENCE_LINK = /\[([^\[\]\n]+)\]\[([^\[\]\n]*)\]/g;
const FOOTNOTE = /\[\^[^\]\s]+\]/g;

function referenceLinks(text: string): Range[] {
  return allMatches(text, REFERENCE_LINK, (m, ranges) => {
    const textEnd = m.index + 1 + m[1].length;
    ranges.push([m.index, m.index + 1], [textEnd, m.index + m[0].length]);
  });
}

// "[ref]: https://example.com "title"" lines; not footnote definitions
const REFERENCE_DEFINITION = /^ {0,3}\[(?!\^)[^\]\n]+\]:[ \t]*\S.*$/gm;
const AUTOLINK = /<(?:[A-Za-z][A-Za-z0-9+.\-]{1,31}:[^\s<>]*|[^\s<>@]+@[^\s<>@]+)>/g;
const HTML_COMMENT = /<!--[\s\S]*?-->/g;
const OBSIDIAN_COMMENT = /%%[\s\S]*?%%/g;
const MATH_BLOCK = /\$\$[\s\S]*?\$\$/g;
const HTML_TAG = /<\/?[A-Za-z][A-Za-z0-9\-]*(?:\s[^<>]*)?\/?>/g;
const EMAIL = /[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}/g;

const BARE_URL = /\b(?:[A-Za-z][A-Za-z0-9+.\-]*:\/\/|www\.)[^\s<>]*/g;
const URL_TRAILER = '.,;:!?\'"*_]';

function bareUrls(text: string): Range[] {
  return allMatches(text, BARE_URL, (m, ranges) => {
    let url = m[0];
    // sentence punctuation after a url is prose; a ")" closes the url only when
    // the url opened one, as in wikipedia links
    for (;;) {
      const last = url[url.length - 1];
      if (URL_TRAILER.indexOf(last) >= 0) {
        url = url.slice(0, -1);
      } else if (last === ')' && url.split('(').length < url.split(')').length) {
        url = url.slice(0, -1);
      } else {
        break;
      }
    }
    ranges.push([m.index, m.index + url.length]);
  });
}

// obsidian tags: # then letters, digits, _ - /, with at least one non-digit, not
// right after a letter, digit or one of _ & # / \ (so not "C#" or "&#12;").
const TAG_BODY = /[\p{L}\p{N}_\-\/]+/uy;
const TAG_BLOCKER = /^[\p{L}\p{N}_&#\/\\]$/u;
const DIGITS = /^[0-9]+$/;

function tags(text: string): Range[] {
  const ranges: Range[] = [];
  // only the # characters are worth a regular expression
  for (let hash = text.indexOf('#'); hash >= 0; hash = text.indexOf('#', hash + 1)) {
    if (hash > 0 && TAG_BLOCKER.test(charBefore(text, hash))) continue;
    TAG_BODY.lastIndex = hash + 1;
    const body = TAG_BODY.exec(text);
    if (body === null || DIGITS.test(body[0])) continue;
    ranges.push([hash, hash + 1 + body[0].length]);
  }
  return ranges;
}

// the whole character (one or two code units) that ends just before i
function charBefore(text: string, i: number): string {
  const low = text.charCodeAt(i - 1);
  const pair = low >= 0xdc00 && low <= 0xdfff && i >= 2;
  return text.slice(pair ? i - 2 : i - 1, i);
}

const CHECKBOX = /^([ \t]*(?:>[ \t]*)*(?:[-*+]|[0-9]+[.)])[ \t]+)\[.\]/gm;

function checkboxes(text: string): Range[] {
  return allMatches(text, CHECKBOX, (m, ranges) => {
    const start = m.index + m[1].length;
    ranges.push([start, start + 3]);
  });
}

const BLOCK_ID = /[ \t](\^[A-Za-z0-9\-]+)[ \t]*$/gm;

function blockIds(text: string): Range[] {
  return allMatches(text, BLOCK_ID, (m, ranges) => {
    ranges.push([m.index + 1, m.index + 1 + m[1].length]);
  });
}

const PHASES: Phase[] = [
  frontmatter,
  fences,
  whole(MATH_BLOCK),
  inlineCode,
  whole(HTML_COMMENT),
  whole(OBSIDIAN_COMMENT),
  inlineMath,
  wikiLinks,
  images,
  links,
  referenceLinks,
  whole(FOOTNOTE),
  whole(REFERENCE_DEFINITION),
  whole(AUTOLINK),
  bareUrls,
  whole(EMAIL),
  whole(HTML_TAG),
  tags,
  checkboxes,
  blockIds,
];
