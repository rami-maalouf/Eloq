import { describe, expect, test } from 'bun:test';
import { maskMarkdown } from './markdown.ts';
import { buildIndex, scan } from './matcher.ts';

// the prose that survives masking, with runs of spaces collapsed and each line
// trimmed for reading
function prose(markdown: string): string {
  const masked = maskMarkdown(markdown);
  expect(masked.length).toBe(markdown.length);
  expect(masked.split('\n').length).toBe(markdown.split('\n').length);
  return masked
    .split('\n')
    .map((line) => line.replace(/[ \t]+/g, ' ').trim())
    .join('\n');
}

describe('maskMarkdown', () => {
  test('frontmatter', () => {
    expect(prose('---\ntitle: Interesting\ntags: [a]\n---\nBody text')).toBe('\n\n\n\nBody text');
    expect(prose('+++\ntitle = "x"\n+++\nBody')).toBe('\n\n\nBody');
    // never closed: not frontmatter
    expect(prose('---\nnot frontmatter')).toBe('---\nnot frontmatter');
  });

  test('fenced code, closed and unclosed', () => {
    expect(prose('before\n```ts\nconst interesting = 1;\n```\nafter')).toBe('before\n\n\n\nafter');
    expect(prose('a\n~~~~\ncode\n~~~\nstill code\n~~~~\nb')).toBe('a\n\n\n\n\n\nb');
    expect(prose('a\n```\nnever closed\nmore')).toBe('a\n\n\n');
  });

  test('inline code, including longer runs and code with backticks', () => {
    expect(prose('use `interesting()` here')).toBe('use here');
    expect(prose('use ``a ` b`` here')).toBe('use here');
    expect(prose('a lone ` backtick stays')).toBe('a lone ` backtick stays');
    expect(prose('not `across\n\nparagraphs`')).toBe('not `across\n\nparagraphs`');
  });

  test('math, inline and block, but not prices', () => {
    expect(prose('so $x^2$ is big')).toBe('so is big');
    expect(prose('see\n$$\n\\frac{a}{b}\n$$\ndone')).toBe('see\n\n\n\ndone');
    expect(prose('it costs $5 and $10 now')).toBe('it costs $5 and $10 now');
    expect(prose('a `$x` b $y$ c')).toBe('a b c');
  });

  test('links keep their text, images go entirely', () => {
    expect(prose('read [the interesting post](https://x.com/a_(b)) now')).toBe('read the interesting post now');
    expect(prose('see ![a diagram](img/a.png "title") here')).toBe('see here');
    expect(prose('a [ref link][1] and [other][]')).toBe('a ref link and other');
    expect(prose('[1]: https://example.com "Title"\ntext')).toBe('\ntext');
  });

  test('wiki links keep only an alias', () => {
    expect(prose('see [[Some Note]] and [[Other Note#Part|this idea]] here')).toBe('see and this idea here');
    expect(prose('an embed ![[image.png]] here')).toBe('an embed here');
  });

  test('bare urls, autolinks and emails, but not the period after them', () => {
    expect(prose('go to https://example.com/path?q=1. Then www.site.org, ok')).toBe('go to . Then , ok');
    expect(prose('mail <me@example.com> or me@example.com or <https://x.y>')).toBe('mail or or');
    expect(prose('(see https://en.wikipedia.org/wiki/Foo_(bar))')).toBe('(see )');
  });

  test('html tags and comments, keeping the text between tags', () => {
    expect(prose('a <span class="x">kept</span> b<br/>')).toBe('a kept b');
    expect(prose('a <!-- hidden\nnote --> b %% obsidian\ncomment %% c')).toBe('a\nb\nc');
  });

  test('tags, but not headings, numbers or anchors', () => {
    expect(prose('#idea some text #area/sub-topic end')).toBe('some text end');
    expect(prose('# Heading\nissue #12 and C# too')).toBe('# Heading\nissue #12 and C# too');
    expect(prose('after 😀#emoji and 𝒜#x, &#38;, (#paren) #ünïcode')).toBe('after 😀 and 𝒜#x, &#38;, ( )');
  });

  test('task checkboxes, footnotes and block ids', () => {
    expect(prose('- [x] done thing\n- [ ] open thing')).toBe('- done thing\n- open thing');
    expect(prose('a claim[^1] here ^block-1\n[^1]: the source')).toBe('a claim here\n: the source');
  });

  test('keeps length, newlines, carriage returns and emoji offsets', () => {
    const note = '😀 `code` 👍🏽\r\nwords';
    const masked = maskMarkdown(note);
    expect(masked).toBe('😀        👍🏽\r\nwords');
  });

  test('scan offsets on a masked note point into the original note', () => {
    const note = '---\ntitle: interesting\n---\nAn `interesting` [interesting](https://interesting.com) idea #interesting';
    const masked = maskMarkdown(note);
    const matches = scan(masked, buildIndex([{ id: 'i', text: 'interesting' }]));
    expect(matches.length).toBe(1);
    expect(note.slice(matches[0].start, matches[0].end)).toBe('interesting');
    expect(matches[0].start).toBe(note.indexOf('[interesting]') + 1);
  });

  test('empty and plain notes', () => {
    expect(maskMarkdown('')).toBe('');
    expect(maskMarkdown('just prose, nothing else.')).toBe('just prose, nothing else.');
  });
});
