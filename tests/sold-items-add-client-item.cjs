const fs=require('fs'),vm=require('vm'),assert=require('node:assert/strict');
const html=fs.readFileSync('index.html','utf8');
const extract=name=>{const start=html.indexOf('function '+name+'('),end=html.indexOf('\nfunction ',start+1);return html.slice(start,end);};
const context={setTimeout(){},toast(){throw Error('Unexpected warning')},renderSoldItemsRows(){},document:{querySelector(){return null}}};
vm.createContext(context);
vm.runInContext(`let _soldItems=[{sr:1,member_id:'a',client_name:'Client A',phone:'0700000000',asset_id:'one',product:'First',quantity:2,loan_amount:2000,loan_term:12},{sr:2,member_id:'b',client_name:'Client B'}]; ${extract('siAddItemForClient')} siAddItemForClient(0); siAddItemForClient(0); result=_soldItems;`,context);
assert.equal(context.result.length,4);
assert.deepEqual(Array.from(context.result,r=>r.member_id),['a','a','a','b']);
for(const row of Array.from(context.result).slice(1,3)){assert.equal(row.phone,'0700000000');assert.equal(row.loan_term,12);assert.equal(row.asset_id,'');assert.equal(row.loan_amount,'');}
assert.equal(context.result[0].loan_amount,2000);
assert.deepEqual(Array.from(context.result,r=>r.sr),[1,2,3,4]);
assert.match(html,/onclick="siAddItemForClient\(\$\{i\}\)">\+ Add item for this client/);
console.log('Multiple items retain the client, start with independent product/amount, preserve prior entries and keep row numbering correct.');
