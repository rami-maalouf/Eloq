// a window with every kind of text field an electron app has, for run.sh: it opens behind the
// other windows and takes no focus. argv[2] places the cursor: "<field id>:<word>".
const { app, BrowserWindow } = require('electron');
if (app.dock) app.dock.hide();
app.whenReady().then(() => {
  const win = new BrowserWindow({ width: 720, height: 600, show: false, title: 'eloq-typing-live', backgroundColor: '#ffffff' });
  win.on('page-title-updated', (e) => e.preventDefault());
  win.loadFile('index.html', { hash: process.argv[2] || '' });
  win.once('ready-to-show', () => win.showInactive());
});
