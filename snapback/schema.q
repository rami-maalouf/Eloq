use personas alice, bob

table notes:
  author: principal
  body: text 1..200
  at: time
  by byTime: at, id
  public 'notes are public'
  insert <- .author = viewer
  update <- deny
  delete <- .author = viewer
  sync public last 100 by byTime

query recent():
  return notes last 50 by byTime

mutation post(body: text 1..200):
  row = insert notes { author: viewer, body, at: now }
  return { id: row.id }
