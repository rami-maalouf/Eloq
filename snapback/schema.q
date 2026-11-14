-- eloq: one person's vocabulary. every row belongs to its owner and syncs to the
-- owner's devices; nothing is shared between accounts.
use identity password

-- a word or phrase. one row can be both overused and a target (as in the old app).
table terms:
  owner: principal
  text: text 1..120
  normalized: text 1..120
  forms: [text 1..120] <=20
  overused: bool default false
  target: bool default false
  meaning: text <=2000 default ''
  nuance: text <=2000 default ''
  whenNotToUse: text <=2000 default ''
  example: text <=2000 default ''
  notes: text <=4000 default ''
  contexts: [text 1..40] <=12
  tags: [text 1..40] <=20
  provenance: enum('user', 'ai', 'agent', 'import_notion', 'import_eloq1', 'import_vocab_enhancer')
  sourceExcerpt: text <=4000 default ''
  externalIds: [text 1..160] <=8
  createdAt: time default now
  updatedAt: time default now
  by byNormalized: owner, normalized, id
  unique owner, normalized else TERM_EXISTS 'That word is already in your library.'
  immutable owner
  cap 5000 by owner
  read <- .owner = viewer
  insert <- .owner = viewer
  update <- .owner = viewer
  delete <- .owner = viewer
  sync to .owner

-- "move from `from` (overused) to `to` (target)".
table links:
  owner: principal
  from: terms on delete cascade
  to: terms on delete cascade
  status: enum('suggested', 'accepted', 'dismissed') default 'accepted'
  origin: enum('user', 'ai', 'agent', 'import')
  confidence: int 0..100 default 100
  rationale: text <=2000 default ''
  useWhen: text <=2000 default ''
  caution: text <=2000 default ''
  example: text <=2000 default ''
  sourceExcerpt: text <=4000 default ''
  externalIds: [text 1..160] <=8
  createdAt: time default now
  updatedAt: time default now
  by byFrom: owner, from, id
  cap 60 by from
  cap 60 by to
  unique owner, from, to else LINK_EXISTS 'Those two words are already linked.'
  immutable owner, from, to
  cap 4000 by owner
  read <- .owner = viewer
  insert <- .owner = viewer
  update <- .owner = viewer
  delete <- .owner = viewer
  sync to .owner

-- daily counts, never text: what was typed or said, per term and source. `term` is a
-- term's id without a reference, so history outlives a deleted word.
table usage:
  owner: principal
  term: id
  day: text 10..10
  channel: enum('typing', 'speech')
  kind: enum('overused_seen', 'swapped', 'kept', 'target_used')
  source: text 1..160
  count: int 0..
  by byDay: owner, day, id
  unique owner, term, day, channel, kind, source
  immutable owner, term, day, channel, kind, source
  cap 200000 by owner
  read <- .owner = viewer
  insert <- .owner = viewer
  update <- .owner = viewer
  delete <- .owner = viewer
  sync to .owner

-- one row per scanned transcript, so a rescan of the same text adds nothing.
table scans:
  owner: principal
  sourceKind: enum('obsidian', 'speech', 'letterly')
  sourceRef: text 1..400
  contentHash: text 1..128
  day: text 10..10
  wordCount: int 0..
  scannedAt: time default now
  by byScanned: owner, scannedAt, id
  unique owner, sourceKind, sourceRef
  immutable owner, sourceKind, sourceRef
  cap 50000 by owner
  read <- .owner = viewer
  insert <- .owner = viewer
  update <- .owner = viewer
  delete <- .owner = viewer
  sync to .owner

query library():
  return terms where .owner = viewer

query allLinks():
  return links where .owner = viewer

query usageSince(day: text 10..10, c: cursor ?):
  return usage[] after c first 500 by byDay where .owner = viewer and .day >= day

query recentScans():
  return scans where .owner = viewer last 200 by byScanned

mutation addTerm(text: text 1..120, normalized: text 1..120, overused: bool, target: bool,
    meaning: text <=2000, example: text <=2000, notes: text <=4000,
    provenance: enum('user', 'ai', 'agent', 'import_notion', 'import_eloq1', 'import_vocab_enhancer')):
  return insert terms { owner: viewer, text, normalized, forms: [], overused, target, meaning,
    example, notes, contexts: [], tags: [], provenance, externalIds: [] }

mutation editTerm(term: terms, text: text 1..120, normalized: text 1..120, forms: [text 1..120] <=20,
    overused: bool, target: bool, meaning: text <=2000, nuance: text <=2000,
    whenNotToUse: text <=2000, example: text <=2000, notes: text <=4000,
    contexts: [text 1..40] <=12, tags: [text 1..40] <=20):
  t = terms[term] ! else NOT_FOUND
  require t.owner = viewer else NOT_FOUND
  update terms[term] { text, normalized, forms, overused, target, meaning, nuance, whenNotToUse,
    example, notes, contexts, tags, updatedAt: now }

mutation removeTerm(term: terms):
  t = terms[term] ! else NOT_FOUND
  require t.owner = viewer else NOT_FOUND
  delete terms[term]

mutation link(from: terms, to: terms, status: enum('suggested', 'accepted', 'dismissed'),
    origin: enum('user', 'ai', 'agent', 'import'), confidence: int 0..100,
    rationale: text <=2000, useWhen: text <=2000, caution: text <=2000, example: text <=2000):
  f = terms[from] ! else NOT_FOUND
  t = terms[to] ! else NOT_FOUND
  require f.owner = viewer and t.owner = viewer else NOT_FOUND
  require from != to else SAME_TERM
  return insert links { owner: viewer, from, to, status, origin, confidence, rationale, useWhen,
    caution, example, externalIds: [] }

mutation setLinkStatus(link: links, status: enum('suggested', 'accepted', 'dismissed')):
  l = links[link] ! else NOT_FOUND
  require l.owner = viewer else NOT_FOUND
  update links[link] { status, updatedAt: now }

mutation editLink(link: links, rationale: text <=2000, useWhen: text <=2000,
    caution: text <=2000, example: text <=2000):
  l = links[link] ! else NOT_FOUND
  require l.owner = viewer else NOT_FOUND
  update links[link] { rationale, useWhen, caution, example, updatedAt: now }

mutation removeLink(link: links):
  l = links[link] ! else NOT_FOUND
  require l.owner = viewer else NOT_FOUND
  delete links[link]

-- adds on the server, so two devices counting offline never overwrite each other.
mutation addUsage(term: terms, day: text 10..10, channel: enum('typing', 'speech'),
    kind: enum('overused_seen', 'swapped', 'kept', 'target_used'), source: text 1..160, count: int 1..):
  t = terms[term] ! else NOT_FOUND
  require t.owner = viewer else NOT_FOUND
  u = usage[owner = viewer, term = term, day = day, channel = channel, kind = kind, source = source]
  if u != null:
    update usage[u.id] { count: u.count + count }
  else:
    insert usage { owner: viewer, term, day, channel, kind, source, count }

-- one scan per transcript; counts go through addUsage. a changed text (new hash)
-- is the caller's to subtract before recording again.
mutation recordScan(sourceKind: enum('obsidian', 'speech', 'letterly'), sourceRef: text 1..400,
    contentHash: text 1..128, day: text 10..10, wordCount: int 0..):
  s = scans[owner = viewer, sourceKind = sourceKind, sourceRef = sourceRef]
  if s != null:
    update scans[s.id] { contentHash, day, wordCount, scannedAt: now }
    return { id: s.id }
  row = insert scans { owner: viewer, sourceKind, sourceRef, contentHash, day, wordCount }
  return { id: row.id }

invariant terms.read only .owner = viewer
invariant links.read only .owner = viewer
invariant usage.read only .owner = viewer
invariant scans.read only .owner = viewer

-- every field at once: the one-time import and agents (through the mcp server) write with these.
mutation importTerm(text: text 1..120, normalized: text 1..120, forms: [text 1..120] <=20,
    overused: bool, target: bool, meaning: text <=2000, nuance: text <=2000,
    whenNotToUse: text <=2000, example: text <=2000, notes: text <=4000,
    contexts: [text 1..40] <=12, tags: [text 1..40] <=20,
    provenance: enum('user', 'ai', 'agent', 'import_notion', 'import_eloq1', 'import_vocab_enhancer'),
    sourceExcerpt: text <=4000, externalIds: [text 1..160] <=8):
  return insert terms { owner: viewer, text, normalized, forms, overused, target, meaning, nuance,
    whenNotToUse, example, notes, contexts, tags, provenance, sourceExcerpt, externalIds }

mutation importLink(from: terms, to: terms, status: enum('suggested', 'accepted', 'dismissed'),
    origin: enum('user', 'ai', 'agent', 'import'), confidence: int 0..100,
    rationale: text <=2000, useWhen: text <=2000, caution: text <=2000, example: text <=2000,
    sourceExcerpt: text <=4000, externalIds: [text 1..160] <=8):
  f = terms[from] ! else NOT_FOUND
  t = terms[to] ! else NOT_FOUND
  require f.owner = viewer and t.owner = viewer else NOT_FOUND
  require from != to else SAME_TERM
  return insert links { owner: viewer, from, to, status, origin, confidence, rationale, useWhen,
    caution, example, sourceExcerpt, externalIds }
