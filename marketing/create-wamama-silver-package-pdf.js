const fs = require('fs');
const path = require('path');

const out = path.join(__dirname, 'wamama-silver-package-clarification-letter.pdf');

function esc(s) {
  return String(s).replace(/\\/g, '\\\\').replace(/\(/g, '\\(').replace(/\)/g, '\\)');
}

function textLine(x, y, size, text, font = 'F1') {
  return `BT /${font} ${size} Tf ${x} ${y} Td (${esc(text)}) Tj ET\n`;
}

function rect(x, y, w, h, color = '0.94 0.97 0.96') {
  return `${color} rg ${x} ${y} ${w} ${h} re f\n`;
}

function strokeRect(x, y, w, h, color = '0.80 0.86 0.84') {
  return `${color} RG ${x} ${y} ${w} ${h} re S\n`;
}

function wrapText(text, maxChars) {
  const words = String(text).split(/\s+/);
  const lines = [];
  let cur = '';
  for (const word of words) {
    if ((cur + ' ' + word).trim().length > maxChars) {
      if (cur) lines.push(cur);
      cur = word;
    } else {
      cur = (cur + ' ' + word).trim();
    }
  }
  if (cur) lines.push(cur);
  return lines;
}

function addParagraph(lines, x, y, size, text, maxChars, gap = 14, font = 'F1') {
  for (const line of wrapText(text, maxChars)) {
    lines.push(textLine(x, y, size, line, font));
    y -= gap;
  }
  return y;
}

function addBullet(lines, x, y, text) {
  lines.push(textLine(x, y, 10.5, '- ' + text));
  return y - 13;
}

function page(content) {
  return [
    'q\n',
    rect(0, 742, 595, 100, '0.07 0.25 0.21'),
    rect(0, 735, 595, 7, '0.78 0.35 0.00'),
    textLine(42, 800, 16, 'RUDDER RESEARCH AND DATA ANALYTICS LTD', 'F2'),
    textLine(42, 780, 10.5, 'System support, performance monitoring and business automation'),
    textLine(455, 800, 10.5, '26 July 2026', 'F2'),
    'Q\n',
    content
  ].join('');
}

function buildPageOne() {
  const l = [];
  let y = 705;
  l.push(textLine(42, y, 18, 'Clarification on the Silver Support Package', 'F2')); y -= 24;
  l.push(textLine(42, y, 10.5, 'Client: Wamama Pamoja Enterprise')); y -= 14;
  l.push(textLine(42, y, 10.5, 'Attention: Leacky Omondi')); y -= 14;
  l.push(textLine(42, y, 10.5, 'Subject: Service commitments, package differences and current usage classification')); y -= 24;

  y = addParagraph(l, 42, y, 10.5,
    'Dear Leacky, thank you for your thoughtful response. We appreciate your request for transparency before the revised support fee takes effect. Any increase in monthly support should be connected to clear service value, measurable performance, reliability and support responsiveness.',
    92);
  y -= 6;

  l.push(rect(42, y - 58, 511, 66, '1.00 0.97 0.90'));
  l.push(strokeRect(42, y - 58, 511, 66, '0.86 0.65 0.22'));
  y = addParagraph(l, 56, y - 12, 10.5,
    'Current position: Wamama Pamoja Enterprise currently falls under the Silver Package. The system now has 12 active business users, more than 1,200 active clients, more than 1,000 active loans, and thousands of savings and repayment records processed every month.',
    84);
  y -= 22;

  l.push(textLine(42, y, 13, 'Current Audit Highlights', 'F2')); y -= 18;
  const cards = [
    ['12', 'Active business users'],
    ['1,221+', 'Active clients'],
    ['1,049+', 'Active loans'],
    ['9,700+', 'Savings and repayment entries monthly']
  ];
  let x = 42;
  for (const [n, label] of cards) {
    l.push(rect(x, y - 58, 118, 62));
    l.push(strokeRect(x, y - 58, 118, 62));
    l.push(textLine(x + 10, y - 20, 18, n, 'F2'));
    l.push(textLine(x + 10, y - 40, 8.5, label));
    x += 131;
  }
  y -= 84;

  l.push(textLine(42, y, 13, 'Package Comparison', 'F2')); y -= 16;
  const rows = [
    ['Starter', 'KES 1,000', '1-3 users, up to 300 clients', 'Very light usage and basic WhatsApp support'],
    ['Bronze', 'KES 3,000', 'Up to 10 users, up to 1,000 clients', 'Basic support, minor fixes and light monitoring'],
    ['Silver', 'KES 6,000', '10-20 users, 1,000-2,000 clients', 'Current Wamama fit: optimization, permissions, reports, backup checks and priority support'],
    ['Gold', 'KES 10,000', '20-40 users, 2,000-5,000 clients', 'Higher volume, branch-level operations and advanced reporting'],
    ['Enterprise', 'KES 15,000+', '40+ users or 5,000+ clients', 'Custom modules, special integrations and dedicated priority support']
  ];
  const col = [42, 112, 190, 326];
  l.push(rect(42, y - 18, 511, 22, '0.07 0.25 0.21'));
  l.push(textLine(col[0] + 5, y - 12, 8.7, 'Package', 'F2'));
  l.push(textLine(col[1] + 5, y - 12, 8.7, 'Fee', 'F2'));
  l.push(textLine(col[2] + 5, y - 12, 8.7, 'Designed For', 'F2'));
  l.push(textLine(col[3] + 5, y - 12, 8.7, 'Coverage', 'F2'));
  y -= 26;
  for (const r of rows) {
    const h = r[0] === 'Silver' ? 52 : 42;
    l.push(strokeRect(42, y - h + 6, 511, h));
    l.push(textLine(col[0] + 5, y - 10, 8.8, r[0], r[0] === 'Silver' ? 'F2' : 'F1'));
    l.push(textLine(col[1] + 5, y - 10, 8.8, r[1], r[0] === 'Silver' ? 'F2' : 'F1'));
    let ty = y - 10;
    for (const line of wrapText(r[2], 24)) {
      l.push(textLine(col[2] + 5, ty, 8.2, line));
      ty -= 10;
    }
    ty = y - 10;
    for (const line of wrapText(r[3], 39)) {
      l.push(textLine(col[3] + 5, ty, 8.2, line));
      ty -= 10;
    }
    y -= h;
  }
  return page(l.join(''));
}

function buildPageTwo() {
  const l = [];
  let y = 705;
  l.push(textLine(42, y, 15, 'What the Silver Package Commits To', 'F2')); y -= 22;
  const commitments = [
    ['Performance', 'Ongoing database optimization, index checks, heavy-table monitoring and review of slow areas such as login, client records, transactions and reports.'],
    ['Reliability', 'Routine checks on savings, repayments, approvals, loans, orders, inventory and reports to reduce disruptions.'],
    ['Support Response', 'Priority WhatsApp support during working hours. Urgent operational blockers are prioritized first.'],
    ['Backups and Data Safety', 'Monthly backup checks and data consistency support. Platform backup depth depends on the hosting/Supabase plan, and Rudder will advise when higher infrastructure becomes necessary.'],
    ['Permissions and Roles', 'Support for user roles, permissions, team visibility, supervisor access, officer book transfers and audit trails.'],
    ['Monthly Review', 'A monthly system health review covering usage growth, performance, pending issues and recommended improvements.']
  ];
  for (const [title, body] of commitments) {
    l.push(textLine(42, y, 10.5, title + ':', 'F2'));
    y = addParagraph(l, 145, y, 9.8, body, 70, 12);
    y -= 4;
  }

  y -= 6;
  l.push(textLine(42, y, 15, 'Why Wamama Falls Under Silver', 'F2')); y -= 20;
  y = addBullet(l, 42, y, 'User load: 12 active business users, already above the Bronze limit.');
  y = addBullet(l, 42, y, 'Client and loan load: more than 1,200 active clients and more than 1,000 active loans.');
  y = addBullet(l, 42, y, 'Operational activity: thousands of savings and repayment records, approvals, inventory/order activity and reports every month.');
  y -= 8;

  l.push(rect(42, y - 58, 511, 66, '1.00 0.97 0.90'));
  l.push(strokeRect(42, y - 58, 511, 66, '0.86 0.65 0.22'));
  y = addParagraph(l, 56, y - 12, 10.5,
    'Important: The upgrade is not a charge for growth alone. It is a support commitment to keep the system stable, monitored, optimized and properly maintained as Wamama continues to expand.',
    84);
  y -= 26;

  l.push(textLine(42, y, 15, 'Future Scalability', 'F2')); y -= 18;
  y = addParagraph(l, 42, y, 10.5,
    'The Silver Package is suitable for Wamama at the current scale. If the business later grows beyond 20 users, 2,000 clients, multiple branches, or requires major new custom workflows, we would review the package again transparently before any further change is made.',
    92);
  y -= 8;

  l.push(textLine(42, y, 15, 'Next Step', 'F2')); y -= 18;
  y = addParagraph(l, 42, y, 10.5,
    'We are available to go through this document together and align expectations before the revised fee takes effect. Our goal is to maintain a long-term partnership that supports Wamama Pamoja Enterprise with clarity, fairness and dependable system performance.',
    92);
  y -= 22;

  l.push(textLine(42, y, 10.5, 'Kind regards,')); y -= 15;
  l.push(textLine(42, y, 10.5, 'Rudder Research Team', 'F2')); y -= 13;
  l.push(textLine(42, y, 10.5, 'Rudder Research and Data Analytics LTD')); y -= 13;
  l.push(textLine(42, y, 10.5, 'admin@rudderdatanalytics.co.ke'));
  return page(l.join(''));
}

const pages = [buildPageOne(), buildPageTwo()];

const objects = [];
function addObject(s) {
  objects.push(s);
  return objects.length;
}

const catalogId = 1;
const pagesId = 2;
addObject(''); // catalog placeholder
addObject(''); // pages placeholder
const font1Id = addObject('<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>');
const font2Id = addObject('<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica-Bold >>');

const pageIds = [];
for (const p of pages) {
  const stream = Buffer.from(p, 'latin1');
  const contentId = addObject(`<< /Length ${stream.length} >>\nstream\n${p}\nendstream`);
  const pageId = addObject(`<< /Type /Page /Parent ${pagesId} 0 R /MediaBox [0 0 595 842] /Resources << /Font << /F1 ${font1Id} 0 R /F2 ${font2Id} 0 R >> >> /Contents ${contentId} 0 R >>`);
  pageIds.push(pageId);
}

objects[catalogId - 1] = `<< /Type /Catalog /Pages ${pagesId} 0 R >>`;
objects[pagesId - 1] = `<< /Type /Pages /Kids [${pageIds.map(id => `${id} 0 R`).join(' ')}] /Count ${pageIds.length} >>`;

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
