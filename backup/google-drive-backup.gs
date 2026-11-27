/**
 * Value Attendance — daily backup to Google Drive (free, runs inside your own Google account).
 *
 * Setup (once):
 *  1. script.google.com → New project → paste this file.
 *  2. Project Settings → Script properties → add BACKUP_TOKEN = the same secret you put on the API host (Vercel).
 *  3. Run `setup` once and allow access to Drive. It creates a daily trigger (around 3 AM)
 *     and takes the first backup right away, and the minute heartbeat (which also sends the daily leads report
 *     from 23:59 Cairo — the GitHub schedule for it is retired, so there is exactly one scheduler).
 *     After updating this file, paste it again and run `setupHeartbeat` once (nothing else changes).
 *
 * Each run writes a folder "Value Attendance Backups/YYYY-MM-DD" with one JSON file per table
 * and keeps the last 30 days. Files are private to your Drive.
 */
const API = 'https://value-attendance-api.valunivo.workers.dev';
const ROOT_FOLDER = 'Value Attendance Backups';
const KEEP_DAYS = 30;

function setup() {
  ScriptApp.getProjectTriggers()
    .filter((t) => t.getHandlerFunction() === 'backup')
    .forEach((t) => ScriptApp.deleteTrigger(t));
  ScriptApp.newTrigger('backup').timeBased().everyDays(1).atHour(3).inTimezone('Africa/Cairo').create();
  setupHeartbeat();
  backup();
}

/**
 * Minute heartbeat (free): the API has no scheduler, so this pokes it every minute in working hours — an
 * overdue permission / visit rings on time and reminders go out even when nobody has the app open.
 */
function setupHeartbeat() {
  ScriptApp.getProjectTriggers()
    .filter((t) => t.getHandlerFunction() === 'heartbeat')
    .forEach((t) => ScriptApp.deleteTrigger(t));
  ScriptApp.newTrigger('heartbeat').timeBased().everyMinutes(1).create();
}

/**
 * Working hours only (Saturday–Thursday 08:00–20:00 Cairo): every ping keeps the free database awake, and
 * keeping it awake around the clock would use up its monthly free compute (100 CU-hours) — the database
 * would then stop until the next month. Outside these hours it sleeps and wakes up on the first request.
 */
function workingHours_() {
  const now = new Date();
  const hour = Number(Utilities.formatDate(now, 'Africa/Cairo', 'H'));
  const day = Utilities.formatDate(now, 'Africa/Cairo', 'u'); // 1 = Monday … 5 = Friday … 7 = Sunday
  return day !== '5' && hour >= 8 && hour < 20;
}

function heartbeat() {
  const token = PropertiesService.getScriptProperties().getProperty('BACKUP_TOKEN');
  // the daily leads report (every day, Friday too): this same minute trigger knocks from 23:59 Cairo until it is sent —
  // the API sends it once per day inside its window (23:55–06:00), so extra knocks only answer already_sent
  if (leadsReportMinute_() && PropertiesService.getScriptProperties().getProperty('LEADS_REPORT_DONE') !== reportDay_()) leadsReport_(token);
  if (!workingHours_()) return;
  if (!token) return;
  UrlFetchApp.fetch(API + '/backup/sweep', { method: 'post', headers: { 'X-Backup-Token': token }, muteHttpExceptions: true });
}

/** the report's day: today at 23:59, yesterday after midnight (Cairo) */
function reportDay_() {
  const now = new Date();
  const hm = Utilities.formatDate(now, 'Africa/Cairo', 'HH:mm');
  const d = hm === '23:59' ? now : new Date(now.getTime() - 3600 * 1000);
  return Utilities.formatDate(d, 'Africa/Cairo', 'yyyy-MM-dd');
}

/** 23:59 and the first 30 minutes after midnight (Cairo): the report's knocking window */
function leadsReportMinute_() {
  const hm = Utilities.formatDate(new Date(), 'Africa/Cairo', 'HH:mm');
  return hm === '23:59' || hm < '00:30';
}

/**
 * Knock for the daily leads report. A missing token, a refused token or an API error THROWS: the execution is marked
 * failed in Apps Script (Executions) and Google e-mails the owner its failure summary — never a silent success.
 */
function leadsReport_(token) {
  if (!token) throw new Error('Daily leads report: add BACKUP_TOKEN in Project Settings → Script properties');
  const res = UrlFetchApp.fetch(API + '/leads/daily-report/run', { method: 'post', headers: { 'X-Backup-Token': token }, muteHttpExceptions: true });
  const code = res.getResponseCode();
  if (code !== 200) throw new Error('Daily leads report → HTTP ' + code + ' ' + res.getContentText().slice(0, 200));
  const out = JSON.parse(res.getContentText());
  if (out.reason === 'mail_off') throw new Error('Daily leads report: email is not set up on the API');
  // done for this report day: no more knocks (each one would wake the database)
  if (out.date && (out.sent || out.reason === 'already_sent' || out.reason === 'no_recipients')) {
    PropertiesService.getScriptProperties().setProperty('LEADS_REPORT_DONE', String(out.date));
  }
  return out;
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
    // pages follow the table's key: `after` (the cursor the previous page returned) exports every row exactly once even
    // while the app is used; `offset` is only the fallback for an API that does not return a cursor yet
    let offset = 0, after = null, part = 1;
    do {
      const q = after ? 'after=' + encodeURIComponent(after) : 'offset=' + offset;
      const page = call_('/backup/table/' + encodeURIComponent(t.table) + '?' + q);
      const name = t.table + (page.next !== null || part > 1 ? '.part' + part : '') + '.json';
      dir.createFile(name, JSON.stringify(page.rows), MimeType.PLAIN_TEXT);
      offset = page.next;
      after = page.after || null;
      part++;
    } while (offset !== null);
    // the rows are encrypted in the files: the count is the one the API gave for the table
    summary.push({ table: t.table, rows: t.rows });
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
