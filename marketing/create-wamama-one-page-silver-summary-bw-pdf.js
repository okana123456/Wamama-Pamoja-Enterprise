const fs = require('fs');
const path = require('path');

const out = path.join(__dirname, 'wamama-one-page-silver-package-summary-black-white.pdf');

function esc(s) {
  return String(s).replace(/\\/g, '\\\\').replace(/\(/g, '\\(').replace(/\)/g, '\\)');
}

function line(x, y, size, text, font = 'F1') {
  return `BT /${font} ${size} Tf ${x} ${y} Td (${esc(text)}) Tj ET\n`;
}

function stroke(x, y, w, h, width = 0.7) {
  return `0 0 0 RG ${width} w ${x} ${y} ${w} ${h} re S\n`;
}

function hline(x1, y, x2, width = 0.7) {
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

function paragraph(parts, x, y, size, text, max, gap = 12.5) {
  for (const item of wrap(text, max)) {
    parts.push(line(x, y, size, item));
    y -= gap;
  }
  return y;
}

const p = [];

// Simple black-and-white letterhead
p.push(line(42, 805, 15, 'RUDDER RESEARCH AND DATA ANALYTICS LTD', 'F2'));
p.push(line(42, 788, 10, 'System support, performance monitoring and business automation'));
p.push(line(442, 805, 10, '26 July 2026', 'F2'));
p.push(hline(42, 775, 553, 1));

let y = 748;
p.push(line(42, y, 15, 'Wamama Pamoja Enterprise - Support Package Summary', 'F2')); y -= 23;
p.push(line(42, y, 10.5, 'Attention: Leacky Omondi')); y -= 14;
p.push(line(42, y, 10.5, 'Subject: Clarification on current support package and service coverage')); y -= 22;

y = paragraph(p, 42, y, 10.5,
  'Thank you for your response and for requesting clarity before the revised support fee takes effect. We agree that any change in monthly support should be clear, measurable, and connected to the value the system brings to your daily operations.',
  92);
y -= 4;
y = paragraph(p, 42, y, 10.5,
  'Based on the current audit, Wamama Pamoja Enterprise now falls under the Silver Package. The system currently has 12 active business users, over 1,200 active clients, over 1,000 active loans, and thousands of savings and repayment entries processed every month.',
  92);
y -= 12;

p.push(line(42, y, 12.5, 'Simple Package Comparison', 'F2')); y -= 17;

const x0 = 42;
const xs = [42, 118, 198, 338];
const rowW = 511;
const headerH = 22;

p.push(stroke(x0, y - headerH + 5, rowW, headerH, 1));
p.push(line(xs[0] + 5, y - 9, 8.5, 'Package', 'F2'));
p.push(line(xs[1] + 5, y - 9, 8.5, 'Monthly Fee', 'F2'));
p.push(line(xs[2] + 5, y - 9, 8.5, 'Best For', 'F2'));
p.push(line(xs[3] + 5, y - 9, 8.5, 'What It Covers', 'F2'));
y -= 22;

const rows = [
  ['Bronze', 'KES 3,000', 'Up to 10 users and up to 1,000 clients.', 'Basic support, minor fixes, light reports support and light monitoring.'],
  ['Silver', 'KES 6,000', '10 to 20 users and 1,000 to 2,000 clients. This is the current Wamama level.', 'Performance monitoring, database optimization, backup checks, roles and permissions support, approvals support, reports support and priority WhatsApp support.'],
  ['Gold', 'KES 10,000', '20 to 40 users and 2,000 to 5,000 clients.', 'Higher-volume support, deeper monitoring, advanced reports and faster handling of urgent operational issues.'],
  ['Enterprise', 'KES 15,000+', 'More than 40 users, 5,000+ clients, multiple branches or custom workflows.', 'Custom modules, special reports, advanced permissions, integrations and dedicated priority support arrangement.']
];

for (const r of rows) {
  const h = r[0] === 'Silver' ? 67 : 52;
  p.push(stroke(x0, y - h + 5, rowW, h));
  p.push(line(xs[0] + 5, y - 10, 8.7, r[0], 'F2'));
  p.push(line(xs[1] + 5, y - 10, 8.7, r[1], r[0] === 'Silver' ? 'F2' : 'F1'));
  let ty = y - 10;
  for (const t of wrap(r[2], 25)) {
    p.push(line(xs[2] + 5, ty, 8, t));
    ty -= 9.5;
  }
  ty = y - 10;
  for (const t of wrap(r[3], 39)) {
    p.push(line(xs[3] + 5, ty, 8, t));
    ty -= 9.5;
  }
  y -= h;
}

y -= 13;
y = paragraph(p, 42, y, 10.5,
  'The Silver Package is recommended because Wamama has moved beyond the Bronze limits in users, clients, loans and daily transaction volume. This package is meant to keep the system fast, stable and properly maintained as the business continues to grow.',
  92);
y -= 4;
y = paragraph(p, 42, y, 10.5,
  'The upgraded setup has been provided this month as a free observation period. If the performance is acceptable during normal operations, the monthly support fee will move to KES 6,000 from next month.',
  92);
y -= 17;

p.push(line(42, y, 10.5, 'Kind regards,')); y -= 15;
p.push(line(42, y, 10.5, 'Rudder Research Team', 'F2')); y -= 13;
p.push(line(42, y, 10.5, 'Rudder Research and Data Analytics LTD')); y -= 13;
p.push(line(42, y, 10.5, 'admin@rudderdatanalytics.co.ke'));

const objects = [];
function addObject(s) {
  objects.push(s);
  return objects.length;
}

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
