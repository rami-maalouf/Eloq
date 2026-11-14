// the one definition of a term's identity. the app, the import, the mcp server and
// every consumer compare words through this, so "Can't stand" and "can’t  stand"
// are the same term.

const APOSTROPHES = /[‘’ʼ`´]/g;
const DASHES = /[‐-―]/g;
const SPACES = /\s+/gu;
// punctuation at either end that is never part of a word or phrase
const EDGES = /^[\s"'“”«»()[\]{}.,;:!?]+|[\s"'“”«»()[\]{}.,;:!?]+$/gu;

export function normalize(text: string): string {
  return text
    .normalize('NFC')
    .replace(APOSTROPHES, "'")
    .replace(DASHES, '-')
    .toLowerCase()
    .replace(SPACES, ' ')
    .replace(EDGES, '')
    .trim();
}
