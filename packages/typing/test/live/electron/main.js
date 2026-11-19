// a window with every kind of text field an electron app has, for run.sh: it opens behind the
// other windows and takes no focus. argv[2] places the cursor: "<field id>:<word>", or
// "<field id>:" for the field alone. argv[3] "front" brings it to the front with the keyboard,
// for the end-to-end run.
const { app, BrowserWindow } = require('electron');
const front = process.argv[3] === 'front';
if (app.dock && !front) app.dock.hide();
app.whenReady().then(() => {
  const win = new BrowserWindow({ width: 720, height: 660, show: false, title: 'eloq-typing-live', backgroundColor: '#ffffff' });
  win.on('page-title-updated', (e) => e.preventDefault());
  win.loadFile('index.html', { hash: process.argv[2] || '' });
  win.once('ready-to-show', () => {
    if (!front) return win.showInactive();
    win.show();
    app.focus({ steal: true });
  });
});
