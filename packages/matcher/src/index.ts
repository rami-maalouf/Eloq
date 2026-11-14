export { normalize } from './normalize.ts';
export { countWords, tokenize, type Token } from './tokenize.ts';
export { expandForms, type TermText } from './forms.ts';
export { buildIndex, scan, type FormEntry, type Match, type MatchIndex, type Term } from './matcher.ts';
export { lookupTyped, tableForTyping, type TypedHit, type TypingTable } from './typing.ts';
export { maskMarkdown } from './markdown.ts';
