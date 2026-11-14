import { expandForms } from './forms.ts';
import { normalize } from './normalize.ts';
import { tokenize } from './tokenize.ts';

export type Term = { id: string; text: string; forms?: string[] };

// one normalized surface form: the terms it belongs to and its length in words
export type FormEntry = { termIds: string[]; words: number };

export type MatchIndex = {
  // normalized form -> the terms that have it. several terms can share a form
  // ("stops" from the term "stop" and the term "stops"); a match keeps all of them.
  forms: Map<string, FormEntry>;
  // the longest form, in words
  maxWords: number;
  // normalized first word of any form -> the longest form starting with it, in
  // words. scan only tries windows that start with one of these words.
  heads: Map<string, number>;
};

export type Match = {
  termIds: string[];
  // the normalized form that matched
  form: string;
  // utf-16 offsets into the scanned text: text.slice(start, end) is the match
  start: number;
  end: number;
};

export function buildIndex(terms: Term[]): MatchIndex {
  const forms = new Map<string, FormEntry>();
  const heads = new Map<string, number>();
  let maxWords = 0;
  for (const term of terms) {
    for (const form of expandForms(term)) {
      const tokens = tokenize(form);
      // a form that starts or ends with a symbol ("c++", "#tag") can never equal a
      // window of words, so it is left out
      if (tokens.length === 0 || tokens[0].start !== 0 || tokens[tokens.length - 1].end !== form.length) {
        continue;
      }
      const words = tokens.length;
      const entry = forms.get(form);
      if (entry === undefined) {
        forms.set(form, { termIds: [term.id], words });
      } else if (entry.termIds.indexOf(term.id) < 0) {
        entry.termIds.push(term.id);
      }
      const head = form.slice(0, tokens[0].end);
      heads.set(head, Math.max(heads.get(head) ?? 0, words));
      maxWords = Math.max(maxWords, words);
    }
  }
  return { forms, maxWords, heads };
}

// finds every term in text. words come from the tokenizer; a window of k words
// matches a form when normalize() of the text from its first word's start to its
// last word's end equals the form and the form has k words. so case, curly
// apostrophes and any run of whitespace (newlines too) between the words do not
// matter, but other punctuation does: "a bunch, of" is not "a bunch of".
//
// matching runs left to right; at each word the longest matching window wins and
// the scan continues after it, so matches never overlap. with the terms
// "a bunch of" and "of people", "a bunch of people" yields only "a bunch of".
export function scan(text: string, index: MatchIndex): Match[] {
  const matches: Match[] = [];
  if (index.forms.size === 0 || text.length === 0) return matches;
  const tokens = tokenize(text);
  // normalizing each distinct word once keeps long texts fast
  const normalized = new Map<string, string>();
  let i = 0;
  while (i < tokens.length) {
    const raw = text.slice(tokens[i].start, tokens[i].end);
    let head = normalized.get(raw);
    if (head === undefined) {
      head = normalize(raw);
      normalized.set(raw, head);
    }
    const longest = index.heads.get(head);
    let taken = 0;
    if (longest !== undefined) {
      for (let k = Math.min(longest, tokens.length - i); k >= 1; k -= 1) {
        const start = tokens[i].start;
        const end = tokens[i + k - 1].end;
        const form = k === 1 ? head : normalize(text.slice(start, end));
        const entry = index.forms.get(form);
        if (entry !== undefined && entry.words === k) {
          matches.push({ termIds: entry.termIds.slice(), form, start, end });
          taken = k;
          break;
        }
      }
    }
    i += taken > 0 ? taken : 1;
  }
  return matches;
}
