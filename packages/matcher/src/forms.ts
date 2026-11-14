import { normalize } from './normalize.ts';
import { tokenize } from './tokenize.ts';

// the surface forms a term matches: the term itself, its explicit forms, and for a
// single word the regular english inflections. every form is normalized.
//
// inflection rules (single-word terms only, see inflect()):
// - only a word that ends in a-z, has at least 2 letters and no apostrophe is
//   inflected ("can't" is not). a hyphenated word counts as one word and is
//   inflected at its end ("follow-up" -> "follow-ups").
// - plural / 3rd person:
//   ends in s, x, z, ch, sh   -> +es        (box -> boxes, watch -> watches)
//   consonant + y             -> y to ies   (try -> tries); vowel + y takes +s (plays)
//   consonant + o             -> +s and +es (go -> gos, goes)
//   otherwise                 -> +s         (make -> makes)
// - past:
//   ends in e                 -> +d         (use -> used)
//   consonant + y             -> y to ied   (try -> tried)
//   otherwise                 -> +ed        (play -> played)
// - present participle:
//   ends in ie                -> ie to ying (lie -> lying)
//   ends in ee, ye, oe        -> +ing       (see -> seeing)
//   other e, word longer than 2 -> drop e +ing (make -> making); "be" -> being
//   otherwise                 -> +ing       (play -> playing)
// - consonant doubling: a word ending consonant-vowel-consonant (the last one not
//   w, x or y; "qu" counts as a consonant) gets the doubled past and participle in
//   addition to the plain ones (stop -> stopped, stopping, and stoped, stoping).
//   english doubles only on a stressed last syllable (prefer -> preferred, but
//   visit -> visited), which spelling does not show, so both are generated.
//
// not generated: -ly, -er, -est (they change the meaning), possessives ('s), and
// irregular forms (make -> made, go -> went): add those as explicit forms.
// multi-word phrases match exactly as written plus their explicit forms.
// some generated forms are not real words ("gos", "stoped"); they only matter if
// they appear in text, where they are almost always a form of the term anyway.

export type TermText = { text: string; forms?: string[] };

export function expandForms(term: TermText): string[] {
  const seen = new Set<string>();
  const out: string[] = [];
  const add = (form: string) => {
    if (form && !seen.has(form)) {
      seen.add(form);
      out.push(form);
    }
  };
  const base = normalize(term.text);
  add(base);
  for (const form of term.forms ?? []) add(normalize(form));
  if (isSingleWord(base)) for (const form of inflect(base)) add(form);
  return out;
}

function isSingleWord(form: string): boolean {
  const tokens = tokenize(form);
  return tokens.length === 1 && tokens[0].start === 0 && tokens[0].end === form.length;
}

const VOWELS = 'aeiou';

function isVowel(c: string): boolean {
  return c.length === 1 && VOWELS.indexOf(c) >= 0;
}

function isConsonant(c: string): boolean {
  return c.length === 1 && c >= 'a' && c <= 'z' && !isVowel(c);
}

function endsConsonantVowelConsonant(word: string): boolean {
  const n = word.length;
  if (n < 3) return false;
  const last = word[n - 1];
  if (!isConsonant(last) || last === 'w' || last === 'x' || last === 'y') return false;
  if (!isVowel(word[n - 2])) return false;
  const before = word[n - 3];
  // "quit": the u after q is a consonant sound
  return isConsonant(before) || (before === 'u' && n >= 4 && word[n - 4] === 'q');
}

function inflect(word: string): string[] {
  const n = word.length;
  const last = word[n - 1];
  if (n < 2 || (!isConsonant(last) && !isVowel(last)) || word.indexOf("'") >= 0) return [];
  const prev = word[n - 2];
  const stem = word.slice(0, n - 1);
  const forms: string[] = [];

  // plural and 3rd person
  if (last === 's' || last === 'x' || last === 'z' || word.endsWith('ch') || word.endsWith('sh')) {
    forms.push(word + 'es');
  } else if (last === 'y' && isConsonant(prev)) {
    forms.push(stem + 'ies');
  } else if (last === 'o' && isConsonant(prev)) {
    forms.push(word + 's', word + 'es');
  } else {
    forms.push(word + 's');
  }

  // past
  if (last === 'e') forms.push(word + 'd');
  else if (last === 'y' && isConsonant(prev)) forms.push(stem + 'ied');
  else forms.push(word + 'ed');

  // present participle
  if (word.endsWith('ie')) forms.push(word.slice(0, n - 2) + 'ying');
  else if (last === 'e' && (prev === 'e' || prev === 'y' || prev === 'o' || n <= 2)) forms.push(word + 'ing');
  else if (last === 'e') forms.push(stem + 'ing');
  else forms.push(word + 'ing');

  // consonant doubling
  if (endsConsonantVowelConsonant(word)) forms.push(word + last + 'ed', word + last + 'ing');

  return forms;
}
