/**
 * Value Attendance — daily backup to Google Drive (free, runs inside your own Google account).
 *
 * Setup (once):
 *  1. script.google.com → New project → paste this file.
 *  2. Project Settings → Script properties → add BACKUP_TOKEN = the same secret you put on Netlify.
 *  3. Run `setup` once and allow access to Drive. It creates a daily trigger (around 3 AM)
 *     and takes the first backup right away.
 *
 * Each run writes a folder "Value Attendance Backups/YYYY-MM-DD" with one JSON file per table
 * and keeps the last 30 days. Files are private to your Drive.
 */
const API = 'https://value-attendance-api.netlify.app';
const ROOT_FOLDER = 'Value Attendance Backups';
const KEEP_DAYS = 30;

function setup() {
  ScriptApp.getProjectTriggers()
    .filter((t) => t.getHandlerFunction() === 'backup')
    .forEach((t) => ScriptApp.deleteTrigger(t));
  ScriptApp.newTrigger('backup').timeBased().everyDays(1).atHour(3).inTimezone('Africa/Cairo').create();
  backup();
}

function call_(path) {
  const token = PropertiesService.getScriptProperties().getProperty('BACKUP_TOKEN');
  if (!token) throw new Error('Add BACKUP_TOKEN in Project Settings → Script properties');
  const res = UrlFetchApp.fetch(API + path, { headers: { 'X-Backup-Token': token }, muteHttpExceptions: true });
  if (res.getResponseCode() !== 200) throw new Error(path + ' → HTTP ' + res.getResponseCode() + ' ' + res.getContentText().slice(0, 200));
  return JSON.parse(res.getContentText());
}

function folder_(parent, name) {
  const it = parent.getFoldersByName(name);
  return it.hasNext() ? it.next() : parent.createFolder(name);
}

function backup() {
  const root = folder_(DriveApp.getRootFolder(), ROOT_FOLDER);
  const day = Utilities.formatDate(new Date(), 'Africa/Cairo', 'yyyy-MM-dd');
  const old = root.getFoldersByName(day);
  while (old.hasNext()) old.next().setTrashed(true); // re-run of the same day replaces it
  const dir = root.createFolder(day);

  const list = call_('/backup/tables');
  const summary = [];
  list.tables.forEach(function (t) {
    let offset = 0, part = 1, total = 0;
    do {
      const page = call_('/backup/table/' + encodeURIComponent(t.table) + '?offset=' + offset);
      const name = t.table + (page.next !== null || part > 1 ? '.part' + part : '') + '.json';
      dir.createFile(name, JSON.stringify(page.rows), MimeType.PLAIN_TEXT);
      total += page.rows.length;
      offset = page.next;
      part++;
    } while (offset !== null);
    summary.push({ table: t.table, rows: total });
  });
  dir.createFile('_summary.json', JSON.stringify({ generatedAt: list.generatedAt, tables: summary }, null, 2), MimeType.PLAIN_TEXT);

  // keep the last KEEP_DAYS days
  const cutoff = new Date(Date.now() - KEEP_DAYS * 86400000);
  const all = root.getFolders();
  while (all.hasNext()) {
    const f = all.next();
    const d = new Date(f.getName() + 'T00:00:00Z');
    if (!isNaN(d.getTime()) && d < cutoff) f.setTrashed(true);
  }
}
