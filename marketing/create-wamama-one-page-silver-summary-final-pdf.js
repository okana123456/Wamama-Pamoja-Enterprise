const fs = require('fs');
const path = require('path');

const out = path.join(__dirname, 'wamama-final-silver-package-summary-black-white.pdf');

function esc(s) {
  return String(s).replace(/\\/g, '\\\\').replace(/\(/g, '\\(').replace(/\)/g, '\\)');
}

function line(x, y, size, text, font = 'F1') {
  return `BT /${font} ${size} Tf ${x} ${y} Td (${esc(text)}) Tj ET\n`;
}

function stroke(x, y, w, h, width = 0.65) {
  return `0 0 0 RG ${width} w ${x} ${y} ${w} ${h} re S\n`;
}

function hline(x1, y, x2, width = 0.8) {
  return `0 0 0 RG ${width} w ${x1} ${y} m ${x2} ${y} l S\n`;
}

function wrap(text, max) {
  const words = String(text).split(/\s+/);
  const lines = [];
  let current = '';
  for (const word of words) {
    const next = (current + ' ' + word).trim();
    if (next.length > max) {
      if (current) lines.push(current);
      current = word;
    } else {
      current = next;
    }
  }
  if (current) lines.push(current);
  return lines;
}

function paragraph(parts, x, y, size, text, max, gap = 11.2) {
  for (const item of wrap(text, max)) {
    parts.push(line(x, y, size, item));
    y -= gap;
  }
  return y;
}

function bullet(parts, x, y, text, max = 88) {
  const lines = wrap(text, max);
  lines.forEach((t, i) => {
    parts.push(line(x, y, 8.9, (i === 0 ? '- ' : '  ') + t));
    y -= 10.4;
  });
  return y;
}

const p = [];

p.push(line(42, 808, 15, 'RUDDER RESEARCH AND DATA ANALYTICS LTD', 'F2'));
p.push(line(42, 791, 10, 'System support, performance monitoring and business automation'));
p.push(line(442, 808, 10, '26 July 2026', 'F2'));
p.push(hline(42, 778, 553, 1));

let y = 752;
p.push(line(42, y, 14.5, 'Wamama Pamoja Enterprise - Support Package Classification', 'F2')); y -= 21;
p.push(line(42, y, 10, 'Attention: Leacky Omondi')); y -= 13;
p.push(line(42, y, 10, 'Subject: Final clarification on Silver Package classification and monthly support coverage')); y -= 20;

y = paragraph(p, 42, y, 9.8,
  'Thank you for the feedback. Based on the completed system audit, Wamama Pamoja Enterprise is now classified under the Silver Package. This is not only because of the number of users, but because of the full operational load the system is now supporting every day.',
  98);
y -= 4;

p.push(line(42, y, 11.5, 'What Wamama Has Been Enjoying Under the Upgraded Setup', 'F2')); y -= 14;
y = bullet(p, 42, y, 'Improved speed after database optimization and performance indexing.');
y = bullet(p, 42, y, 'Support for savings, repayments, loans, approvals, reports, inventory, orders and staff permissions.');
y = bullet(p, 42, y, 'Duplicate-entry controls, approval workflow improvements, officer permissions and supervisor/team access setup.');
y = bullet(p, 42, y, 'Ongoing troubleshooting, issue fixes, data checks, monthly review and priority WhatsApp support during working hours.');
y -= 8;

p.push(line(42, y, 11.5, 'Audit Evidence Supporting the Silver Package', 'F2')); y -= 14;
y = bullet(p, 42, y, '12 active business users, excluding Rudder support/test accounts.');
y = bullet(p, 42, y, '1,221 active clients and 1,049 active loans currently being managed.');
y = bullet(p, 42, y, '4,839 savings entries and 4,885 repayment entries processed in the last 30 days.');
y = bullet(p, 42, y, '331 orders created in the last 30 days, meaning the system is also supporting inventory and order operations.');
y = bullet(p, 42, y, 'Multiple roles are actively using the system: admin, branch manager, inventory officer, storekeeper, loan officers and officers.');
y = bullet(p, 42, y, 'Some users have broad permissions across savings, repayments, orders, inventory, suppliers and reports, so the system is supporting several departments, not one user only.');
y -= 8;

p.push(line(42, y, 11.5, 'Package Comparison', 'F2')); y -= 15;

const x0 = 42;
const xs = [42, 110, 188, 326];
const rowW = 511;
const headerH = 20;
p.push(stroke(x0, y - headerH + 5, rowW, headerH, 0.9));
p.push(line(xs[0] + 5, y - 8, 8, 'Package', 'F2'));
p.push(line(xs[1] + 5, y - 8, 8, 'Fee', 'F2'));
p.push(line(xs[2] + 5, y - 8, 8, 'Limit', 'F2'));
p.push(line(xs[3] + 5, y - 8, 8, 'Coverage', 'F2'));
y -= 20;

const rows = [
  ['Bronze', 'KES 3,000', 'Up to 10 users and 1,000 clients.', 'Light usage, basic support, minor fixes and basic monitoring.'],
  ['Silver', 'KES 6,000', '10-20 users and 1,000-2,000 clients.', 'Current Wamama level: performance monitoring, database optimization, backups checks, reports, permissions, approvals, inventory/orders and priority support.'],
  ['Gold', 'KES 10,000', '20-40 users and 2,000-5,000 clients.', 'Higher-volume operations, deeper monitoring, advanced reports and faster urgent support.'],
  ['Enterprise', 'KES 15,000+', '40+ users, 5,000+ clients or branches.', 'Custom modules, integrations, special reports and dedicated priority support.']
];

for (const r of rows) {
  const h = r[0] === 'Silver' ? 58 : 45;
  p.push(stroke(x0, y - h + 5, rowW, h, r[0] === 'Silver' ? 1.1 : 0.65));
  p.push(line(xs[0] + 5, y - 9, 8.2, r[0], 'F2'));
  p.push(line(xs[1] + 5, y - 9, 8.2, r[1], r[0] === 'Silver' ? 'F2' : 'F1'));
  let ty = y - 9;
  for (const t of wrap(r[2], 24)) {
    p.push(line(xs[2] + 5, ty, 7.6, t));
    ty -= 8.8;
  }
  ty = y - 9;
  for (const t of wrap(r[3], 42)) {
    p.push(line(xs[3] + 5, ty, 7.6, t));
    ty -= 8.8;
  }
  y -= h;
}

y -= 10;
y = paragraph(p, 42, y, 9.8,
  'Conclusion: Wamama has already exceeded the Bronze Package. The applicable support category is Silver at KES 6,000 per month. The upgraded setup was provided this month as a free observation period; from next month, the account will be maintained under the Silver Package to keep the system stable, fast and properly supported.',
  98);
y -= 10;

p.push(line(42, y, 9.8, 'Kind regards,')); y -= 13;
p.push(line(42, y, 9.8, 'Rudder Research Team', 'F2')); y -= 12;
p.push(line(42, y, 9.8, 'Rudder Research and Data Analytics LTD')); y -= 12;
p.push(line(42, y, 9.8, 'admin@rudderdatanalytics.co.ke'));

const objects = [];
function addObject(s) { objects.push(s); return objects.length; }

const catalogId = 1;
const pagesId = 2;
addObject('');
addObject('');
const font1Id = addObject('<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>');
const font2Id = addObject('<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica-Bold >>');
const content = p.join('');
const contentId = addObject(`<< /Length ${Buffer.byteLength(content, 'latin1')} >>\nstream\n${content}\nendstream`);
const pageId = addObject(`<< /Type /Page /Parent ${pagesId} 0 R /MediaBox [0 0 595 842] /Resources << /Font << /F1 ${font1Id} 0 R /F2 ${font2Id} 0 R >> >> /Contents ${contentId} 0 R >>`);
objects[catalogId - 1] = `<< /Type /Catalog /Pages ${pagesId} 0 R >>`;
objects[pagesId - 1] = `<< /Type /Pages /Kids [${pageId} 0 R] /Count 1 >>`;

let pdf = '%PDF-1.4\n';
const offsets = [0];
for (let i = 0; i < objects.length; i++) {
  offsets.push(Buffer.byteLength(pdf, 'latin1'));
  pdf += `${i + 1} 0 obj\n${objects[i]}\nendobj\n`;
}
const xref = Buffer.byteLength(pdf, 'latin1');
pdf += `xref\n0 ${objects.length + 1}\n`;
pdf += '0000000000 65535 f \n';
for (let i = 1; i < offsets.length; i++) {
  pdf += `${String(offsets[i]).padStart(10, '0')} 00000 n \n`;
}
pdf += `trailer\n<< /Size ${objects.length + 1} /Root ${catalogId} 0 R >>\nstartxref\n${xref}\n%%EOF\n`;
fs.writeFileSync(out, Buffer.from(pdf, 'latin1'));
console.log(out);
