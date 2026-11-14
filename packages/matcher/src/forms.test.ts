import { describe, expect, test } from 'bun:test';
import { expandForms } from './forms.ts';

function forms(text: string, extra?: string[]): string[] {
  return expandForms({ text, forms: extra });
}

describe('expandForms', () => {
  test('stop doubles its consonant', () => {
    expect(forms('stop')).toEqual(['stop', 'stops', 'stoped', 'stoping', 'stopped', 'stopping']);
  });

  test('consonant + y turns into ies and ied', () => {
    const out = forms('try');
    expect(out).toContain('tries');
    expect(out).toContain('tried');
    expect(out).toContain('trying');
    expect(out).not.toContain('trys');
  });

  test('vowel + y keeps the y', () => {
    expect(forms('play')).toEqual(['play', 'plays', 'played', 'playing']);
  });

  test('a silent e is dropped before ing', () => {
    expect(forms('make')).toEqual(['make', 'makes', 'maked', 'making']);
    expect(forms('use')).toContain('used');
  });

  test('ee, ye, oe and ie endings', () => {
    expect(forms('see')).toContain('seeing');
    expect(forms('agree')).toContain('agreed');
    expect(forms('lie')).toContain('lying');
    expect(forms('be')).toContain('being');
  });

  test('sibilants take es', () => {
    expect(forms('box')).toEqual(['box', 'boxes', 'boxed', 'boxing']);
    expect(forms('watch')).toContain('watches');
    expect(forms('wish')).toContain('wishes');
    expect(forms('focus')).toContain('focuses');
  });

  test('consonant + o takes s and es', () => {
    expect(forms('go')).toEqual(['go', 'gos', 'goes', 'goed', 'going']);
  });

  test('x, w and y are never doubled; qu counts as a consonant', () => {
    expect(forms('fix')).not.toContain('fixxed');
    expect(forms('show')).not.toContain('showwing');
    expect(forms('quit')).toContain('quitting');
  });

  test('no -ly or comparative forms', () => {
    const out = forms('quick');
    expect(out).not.toContain('quickly');
    expect(out).not.toContain('quicker');
    expect(out).not.toContain('quickest');
  });

  test('hyphenated words inflect at the end', () => {
    expect(forms('follow-up')).toContain('follow-ups');
  });

  test('contractions, numbers and single letters are not inflected', () => {
    expect(forms("can't")).toEqual(["can't"]);
    expect(forms('2024')).toEqual(['2024']);
    expect(forms('a')).toEqual(['a']);
  });

  test('phrases stay exact plus explicit forms', () => {
    expect(forms('a bunch of')).toEqual(['a bunch of']);
    expect(forms('make sense', ['makes sense', 'made sense'])).toEqual(['make sense', 'makes sense', 'made sense']);
  });

  test('everything is normalized and deduped, explicit forms first', () => {
    expect(forms('  Stop ', ['STOPPED', 'halt'])).toEqual(['stop', 'stopped', 'halt', 'stops', 'stoped', 'stoping', 'stopping']);
    expect(forms('Can’t Stand')).toEqual(["can't stand"]);
  });
});
