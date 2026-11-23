import { ok, type Module } from '../ctx.ts';
import { one, type Db, type Q } from '../db.ts';
import { forbidden, invalid } from '../http/errors.ts';
import { adminOfficerSql, audit, authenticate, has, notSettled } from '../auth/context.ts';
import { local } from '../lib/time.ts';
import { mailEnabled, sendMail } from '../lib/mail.ts';
import { hasBackupToken } from '../lib/backup-token.ts';
import { STAGE_AR, type Stage } from './leads.ts';

/**
 * «تقرير الليدز اليومي» — every day at 23:59 Cairo an email to the general manager(s) and the administrative officer:
 * the leads added that day, every action on them, and who worked most. Owner's request 2026-11-23.
 *
 * The trigger (a scheduled GitHub workflow, see .github/workflows/leads-daily-report.yml) only knocks on
 * /leads/daily-report/run with the X-Backup-Token secret; the server decides: it sends only inside the day's window (from 23:55 Cairo until 06:00 the
 * next morning, for a late scheduler) and only once per day (kept in the audit log, under a lock) — so a call at any other
 * time, or a second call, sends nothing. Nobody can make it send early, twice, or to anyone else.
 */

const WINDOW_FROM = 23 * 60 + 55; // 23:55
const WINDOW_LATE = 6 * 60; // until 06:00 the next morning

const esc = (s: unknown) => String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]!));
const prevDay = (d: string) => new Date(Date.parse(d + 'T12:00:00Z') - 86_400_000).toISOString().slice(0, 10);

/** which day's report is due at this moment (Cairo), or null outside the window */
export function dueReportDate(now: Date): string | null {
  const l = local(now);
  if (l.minutes >= WINDOW_FROM) return l.date;
  if (l.minutes < WINDOW_LATE) return prevDay(l.date);
  return null;
}

const DAY = (col: string) => `(${col} AT TIME ZONE 'Africa/Cairo')::date = $1::date`;

export async function dailyLeadsData(q: Q, date: string) {
  const leads = (await q.query(`
    SELECT l.ref_no, l.full_name, l.phone, l.kind, l.created_at, p.name AS project, ch.name AS channel, e.full_name AS assigned,
           (l.duplicate_of IS NOT NULL) AS duplicate
      FROM leads l LEFT JOIN commission_projects p ON p.id = l.project_id LEFT JOIN lead_channels ch ON ch.id = l.channel_id
      LEFT JOIN employees e ON e.id = l.assigned_to
     WHERE ${DAY('l.created_at')} ORDER BY l.created_at`, [date])).rows;
  const actions = (await q.query(`
    SELECT x.created_at, x.stage, x.answered, x.comment, l.ref_no, l.full_name AS lead, e.full_name AS by
      FROM lead_actions x JOIN leads l ON l.id = x.lead_id LEFT JOIN employees e ON e.id = x.by_id
     WHERE ${DAY('x.created_at')} AND x.parent_id IS NULL AND NOT x.auto ORDER BY x.created_at`, [date])).rows;
  const contacts = await one(q, `
    SELECT count(*) FILTER (WHERE kind = 'call')::int AS calls, count(*) FILTER (WHERE kind = 'whatsapp')::int AS whatsapp
      FROM lead_logs WHERE kind IN ('call', 'whatsapp') AND ${DAY('created_at')}`, [date]);
  // everyone who works leads (the salespeople and their managers), most work first
  const people = (await q.query(`
    SELECT e.id, e.full_name,
           (SELECT count(*) FROM lead_actions x WHERE x.by_id = e.id AND x.parent_id IS NULL AND NOT x.auto AND ${DAY('x.created_at')})::int AS actions,
           (SELECT count(*) FROM lead_logs g WHERE g.by_id = e.id AND g.kind = 'call' AND ${DAY('g.created_at')})::int AS calls,
           (SELECT count(*) FROM lead_logs g WHERE g.by_id = e.id AND g.kind = 'whatsapp' AND ${DAY('g.created_at')})::int AS whatsapp,
           (SELECT count(*) FROM lead_actions x WHERE x.by_id = e.id AND x.parent_id IS NULL AND NOT x.auto AND ${DAY('x.created_at')}
               AND x.stage IN ('meeting', 'after_meeting'))::int AS meetings,
           (SELECT count(*) FROM leads l WHERE l.assigned_to = e.id AND l.stage = 'done_deal' AND ${DAY('l.stage_changed_at')})::int AS deals,
           (SELECT count(*) FROM leads l WHERE l.assigned_to = e.id AND ${DAY('l.created_at')})::int AS new_leads
      FROM employees e
     WHERE e.status = 'active' AND ${notSettled('e')} AND e.role_key NOT IN ('owner', 'manager') AND NOT ${adminOfficerSql('e')}
       AND EXISTS (SELECT 1 FROM role_permissions rp WHERE rp.role_key = COALESCE(e.position_key, e.role_key) AND rp.perm_key = 'leads.own')
     ORDER BY e.full_name`, [date])).rows;
  const ranked = people.map((p) => ({ name: p.full_name as string, actions: p.actions as number, calls: p.calls as number,
    whatsapp: p.whatsapp as number, meetings: p.meetings as number, deals: p.deals as number, newLeads: p.new_leads as number }));
  ranked.sort((a, b) => b.deals - a.deals || b.actions - a.actions || (b.calls + b.whatsapp) - (a.calls + a.whatsapp) || a.name.localeCompare(b.name));
  const top = ranked.find((p) => p.actions + p.calls + p.whatsapp + p.deals > 0) ?? null;
  return {
    date,
    newLeads: leads.map((l) => ({ refNo: Number(l.ref_no), name: l.full_name as string, phone: l.phone as string, kind: l.kind as string,
      at: new Date(l.created_at), project: l.project as string | null, channel: l.channel as string | null, assigned: l.assigned as string | null,
      duplicate: !!l.duplicate })),
    actions: actions.map((x) => ({ at: new Date(x.created_at), stage: x.stage as string, answered: x.answered as boolean | null,
      comment: String(x.comment ?? ''), refNo: Number(x.ref_no), lead: x.lead as string, by: (x.by as string | null) ?? '—' })),
    calls: contacts?.calls ?? 0, whatsapp: contacts?.whatsapp ?? 0,
    people: ranked, top,
  };
}
export type DailyLeads = Awaited<ReturnType<typeof dailyLeadsData>>;

const hm = (d: Date) => new Intl.DateTimeFormat('en-GB', { timeZone: 'Africa/Cairo', hour: '2-digit', minute: '2-digit', hour12: false }).format(d);
const arDate = (d: string) => new Intl.DateTimeFormat('ar-EG', { timeZone: 'UTC', weekday: 'long', day: 'numeric', month: 'long', year: 'numeric' })
  .format(new Date(d + 'T12:00:00Z'));
const stageAr = (s: string) => STAGE_AR[s as Stage] ?? s;

export function dailyLeadsMail(r: DailyLeads, toName: string) {
  const th = (t: string) => `<th style="padding:8px 10px;background:#1f1f23;color:#ff8a63;font-size:13px;text-align:right;border-bottom:1px solid #333">${t}</th>`;
  const td = (t: unknown, strong = false) => `<td style="padding:7px 10px;border-bottom:1px solid #26262b;font-size:13px;color:#e8e6e3;text-align:right;${strong ? 'font-weight:700' : ''}">${esc(t)}</td>`;
  const table = (head: string[], rows: string[][]) => rows.length
    ? `<table role="presentation" width="100%" style="border-collapse:collapse;margin:6px 0 18px 0"><tr>${head.map(th).join('')}</tr>${rows.map((r) => `<tr>${r.join('')}</tr>`).join('')}</table>`
    : `<p style="color:#a8a49c;font-size:13px;margin:4px 0 18px 0">مفيش</p>`;
  const kpi = (label: string, v: number | string) => `<td style="padding:12px;background:#17171a;border:1px solid #2a2a2e;border-radius:12px;text-align:center">
      <div style="font-size:22px;font-weight:800;color:#ffffff">${esc(v)}</div><div style="font-size:12px;color:#a8a49c">${esc(label)}</div></td>`;
  const h2 = (t: string) => `<h2 style="font-size:16px;color:#ffffff;margin:22px 0 6px 0">${esc(t)}</h2>`;
  const CAP = 200;
  const leadsRows = r.newLeads.slice(0, CAP).map((l) => [td(l.refNo), td(l.name, true), td(l.phone), td(l.project ?? '—'), td(l.channel ?? '—'),
    td(l.assigned ?? 'مش متوزع'), td(hm(l.at)), td(l.duplicate ? 'مكرر' : l.kind === 'cold' ? 'بارد' : 'جديد')]);
  const actionRows = r.actions.slice(0, CAP).map((x) => [td(hm(x.at)), td(x.by, true), td(`${x.lead} (#${x.refNo})`), td(stageAr(x.stage)),
    td(x.answered === false ? 'مردش' : x.answered === true ? 'رد' : '—'), td(x.comment.length > 140 ? x.comment.slice(0, 140) + '…' : x.comment)]);
  const peopleRows = r.people.map((p, i) => [td(i + 1), td(p.name, true), td(p.actions), td(p.calls), td(p.whatsapp), td(p.meetings), td(p.deals), td(p.newLeads)]);
  const idle = r.people.filter((p) => p.actions + p.calls + p.whatsapp === 0).map((p) => p.name);
  const more = (n: number) => n > CAP ? `<p style="color:#a8a49c;font-size:12px">… و${n - CAP} كمان — كلهم في لوحة السيلز</p>` : '';
  const topLine = r.top
    ? `<div style="background:linear-gradient(135deg,#d4401a,#ff6a3d);border-radius:14px;padding:14px 16px;margin:16px 0">
         <div style="font-size:12px;color:#ffe3d8">أكتر سيلز اشتغل النهارده</div>
         <div style="font-size:20px;font-weight:800;color:#ffffff">🏆 ${esc(r.top.name)}</div>
         <div style="font-size:13px;color:#fff3ee">${r.top.actions} أكشن · ${r.top.calls} مكالمة · ${r.top.whatsapp} واتساب${r.top.meetings ? ` · ${r.top.meetings} اجتماع` : ''}${r.top.deals ? ` · ${r.top.deals} صفقة` : ''}</div>
       </div>`
    : `<p style="color:#a8a49c">محدش من السيلز سجّل شغل على الليدز النهارده.</p>`;
  const html = `<!DOCTYPE html><html lang="ar" dir="rtl"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>تقرير الليدز اليومي - VALUNIVO</title></head>
<body style="margin:0;padding:0;background:#09090b;color:#ffffff;direction:rtl;font-family:'Cairo','Segoe UI',Tahoma,Arial,sans-serif">
<div style="display:none;max-height:0;overflow:hidden">${esc(`${r.newLeads.length} ليد جديد · ${r.actions.length} أكشن${r.top ? ` · الأول ${r.top.name}` : ''}`)}</div>
<table role="presentation" width="100%" style="background:#09090b"><tr><td align="center" style="padding:20px 10px">
<table role="presentation" width="100%" style="max-width:860px;background:#111113;border:1px solid #232326;border-radius:18px"><tr><td style="padding:24px 22px">
  <div style="font-size:13px;color:#ff8a63;font-weight:700">VALUNIVO</div>
  <h1 style="font-size:22px;margin:4px 0 2px 0;color:#ffffff">تقرير الليدز اليومي</h1>
  <div style="font-size:13px;color:#a8a49c">${esc(arDate(r.date))} — أهلاً ${esc(toName || '')}</div>
  <table role="presentation" width="100%" style="margin-top:16px;border-collapse:separate;border-spacing:6px"><tr>
    ${kpi('ليد جديد', r.newLeads.length)}${kpi('أكشن', r.actions.length)}${kpi('مكالمة', r.calls)}${kpi('واتساب', r.whatsapp)}
  </tr></table>
  ${topLine}
  ${h2('شغل السيلز النهارده')}
  ${table(['#', 'السيلز', 'أكشنز', 'مكالمات', 'واتساب', 'اجتماعات', 'صفقات', 'ليدز جديدة'], peopleRows)}
  ${idle.length ? `<p style="color:#ffb4a6;font-size:13px;margin:-8px 0 16px 0">ماسجلوش أي شغل النهارده: ${esc(idle.join('، '))}</p>` : ''}
  ${h2(`الليدز الجديدة (${r.newLeads.length})`)}
  ${table(['رقم', 'الاسم', 'الموبايل', 'المشروع', 'القناة', 'السيلز', 'الساعة', 'النوع'], leadsRows)}${more(r.newLeads.length)}
  ${h2(`الأكشنز (${r.actions.length})`)}
  ${table(['الساعة', 'السيلز', 'العميل', 'المرحلة', 'الرد', 'التعليق'], actionRows)}${more(r.actions.length)}
  <p style="color:#6f6b64;font-size:11px;margin-top:22px">بيتبعت تلقائي كل يوم الساعة 11:59 مساءً بتوقيت القاهرة للمدير العام والمسؤول الإداري.</p>
</td></tr></table></td></tr></table></body></html>`;
  const text = [`تقرير الليدز اليومي — ${r.date}`, `ليدز جديدة: ${r.newLeads.length} · أكشنز: ${r.actions.length} · مكالمات: ${r.calls} · واتساب: ${r.whatsapp}`,
    r.top ? `أكتر سيلز اشتغل: ${r.top.name} (${r.top.actions} أكشن)` : 'محدش سجّل شغل النهارده', '',
    ...r.people.map((p, i) => `${i + 1}. ${p.name}: ${p.actions} أكشن، ${p.calls} مكالمة، ${p.whatsapp} واتساب، ${p.deals} صفقة`), '',
    'الليدز الجديدة:', ...r.newLeads.slice(0, CAP).map((l) => `#${l.refNo} ${l.name} — ${l.project ?? '—'} — ${l.assigned ?? 'مش متوزع'} (${hm(l.at)})`)].join('\n');
  return { subject: `تقرير الليدز — ${r.date}: ${r.newLeads.length} ليد جديد، ${r.actions.length} أكشن${r.top ? `، الأول ${r.top.name}` : ''}`, html, text };
}

/** the general manager(s) and the administrative officer(s) with an email */
async function recipients(q: Q) {
  return (await q.query(`
    SELECT e.id, e.full_name, e.email FROM employees e
     WHERE e.status = 'active' AND ${notSettled('e')} AND COALESCE(trim(e.email), '') <> ''
       AND (e.role_key IN ('owner', 'manager') OR ${adminOfficerSql('e')}) ORDER BY e.full_name`)).rows as { id: string; full_name: string; email: string }[];
}

/** send the day's report once (lock + audit log); returns what happened */
export async function runDailyLeadsReport(db: Db, now: Date, opts: { send?: typeof sendMail } = {}) {
  const date = dueReportDate(now);
  if (!date) return { sent: false, reason: 'not_due' as const };
  const send = opts.send ?? sendMail;
  return db.tx(async (q) => {
    await q.query(`SELECT pg_advisory_xact_lock(hashtextextended('leads_daily_report', 0))`);
    if (await one(q, `SELECT 1 FROM audit_log WHERE action = 'leads.daily_report' AND entity = 'leads_daily_report' AND entity_id = $1`, [date])) {
      return { sent: false, reason: 'already_sent' as const, date };
    }
    const to = await recipients(q);
    const data = await dailyLeadsData(q, date);
    const results: { id: string; ok: boolean }[] = [];
    for (const r of to) {
      const m = dailyLeadsMail(data, r.full_name);
      let okSent = false;
      try { okSent = await send({ to: r.email, toName: r.full_name, subject: m.subject, html: m.html, text: m.text }); } catch { okSent = false; }
      results.push({ id: r.id, ok: okSent });
    }
    // recorded even when nobody could be mailed — the day is done (no retry storm); who got it is kept
    await audit(q, null, 'leads.daily_report', 'leads_daily_report', date, undefined, {
      date, newLeads: data.newLeads.length, actions: data.actions.length, top: data.top?.name ?? null,
      sentTo: results.filter((x) => x.ok).map((x) => x.id), failed: results.filter((x) => !x.ok).map((x) => x.id),
    });
    return { sent: results.some((x) => x.ok), reason: to.length ? 'done' as const : 'no_recipients' as const, date,
      delivered: results.filter((x) => x.ok).length, recipients: to.length };
  });
}

export const leadsDailyModule: Module = (r, { db, clock }) => {
  // the scheduler's knock (2026-11-24: no longer anonymous): the scheduler sends the host's BACKUP_TOKEN in X-Backup-Token
  // (the same secret the owner's Apps Script already uses); a signed-in person needs «leads.read_all» (owner / GM / admin
  // officer). Either way the server still sends only in the window, once a day, to the fixed recipients.
  r.post('/leads/daily-report/run', async (req) => {
    if (!hasBackupToken(req.headers)) {
      const a = await authenticate(db, req);
      if (!has(a, 'leads.read_all')) throw forbidden();
    }
    if (!mailEnabled()) return ok({ sent: false, reason: 'mail_off' });
    return ok(await runDailyLeadsReport(db, clock()));
  });

  // a preview of any day's report for the owner / GM / admin officer (the same content, nothing sent)
  r.get('/leads/daily-report', async (req) => {
    const a = await authenticate(db, req);
    if (!has(a, 'leads.read_all')) throw forbidden();
    const date = req.query.get('date') ?? local(clock()).date;
    if (!/^\d{4}-\d{2}-\d{2}$/.test(date)) throw invalid('date: YYYY-MM-DD', { field: 'date' });
    const d = await dailyLeadsData(db, date);
    return ok({ report: { ...d, newLeads: d.newLeads.length, actions: d.actions.length } });
  });
};
