const assert=require('node:assert/strict');
const fs=require('node:fs'),path=require('node:path'),vm=require('node:vm');
const html=fs.readFileSync(path.join(__dirname,'../index.html'),'utf8');
const script=html.match(/<script>\s*([\s\S]*?)<\/script>/)[1];
const page={innerHTML:''};
const search={value:'',selectionStart:0,addEventListener(type,callback){this.onInput=callback;},focus(){},setSelectionRange(){}};
const loanSearch={...search},memberSearch={...search};
const select={addEventListener(){}};
const timers=new Map();let timerId=0;
let nextLineId=0;
const sandbox={WamamaFinance:require('../financial-rules.js'),console,Intl,Date,URL,Map,Set,Promise,
 crypto:{randomUUID:()=>`line-${++nextLineId}`},
 window:{addEventListener(){}},document:{addEventListener(){},getElementById(id){
  if(id==='page') return page;if(id==='inv-search') return search;
  if(id==='loan-search') return loanSearch;
  if(id==='mem-search') return memberSearch;
  if(id==='mem-group'||id==='mem-status') return select;
  if(id==='pur-f') return {};
  if(id==='af') return {kind:'asset',dataset:{existing:'1'}};
  if(id==='pur-total-override') return {value:''};
  return null;
 },querySelector:()=>null},navigator:{onLine:true},
 localStorage:{getItem:()=>null,setItem(){},removeItem(){}},sessionStorage:{getItem:()=>null,setItem(){},removeItem(){}},
 setInterval(){},setTimeout(callback){const id=++timerId;timers.set(id,callback);return id;},clearTimeout(id){timers.delete(id);},
 requestAnimationFrame(callback){callback();},
 FormData:class{constructor(node){this.node=node;}*[Symbol.iterator](){
  if(this.node?.kind==='asset'){for(const pair of sandbox.assetFields) yield pair;return;}
  yield ['supplier_id','supplier'];yield ['received_on','2026-10-04'];
 }},
 supabase:{createClient:()=>({auth:{onAuthStateChange(){}}})}};
vm.createContext(sandbox);
vm.runInContext(script.slice(0,script.indexOf('(async function boot(){')),sandbox);
const run=code=>vm.runInContext(code,sandbox);
assert.equal(run(`inventoryReceiptCost({buying_price:10000,stock:10,cost_method:'weighted_average'},10,10500,0)`),10250);
assert.equal(run(`inventoryReceiptCost({buying_price:10000,stock:10,cost_method:'weighted_average'},10,10500,500)`),10500);
assert.equal(run(`inventoryReceiptCost({buying_price:10000,stock:10,cost_method:'latest_purchase'},10,10500,-200)`),10300);
assert.equal(run(`inventoryReceiptCost({buying_price:10000,stock:10,cost_method:'manual'},10,10500,500)`),10000);
assert.equal(run(`inventoryPurchasePrice({buying_price:10000})`),null,'legacy valuation cost is not falsely presented as an actual supplier price');
assert.equal(run(`inventoryMarginPct(14000,10500)`),'25.0%');
assert.equal(run(`inventoryMarginPct(14000,null)`),'—');
assert.throws(()=>run(`inventoryReceiptCost({buying_price:10000,stock:10},1,100,-150)`),/zero or greater/);

 run(`state.staff={id:'manager',role:'admin',app_role:'admin',business_id:'business'};
 state.data.inventory=[{id:'asset',name:'Sofa',category:'Furniture',stock:10,buying_price:10000,
  purchase_price:10000,cost_method:'weighted_average',cost_adjustment:0,loan_price:14000,reorder_level:2},
  {id:'other',name:'Chair',category:'Furniture',stock:1,buying_price:1000,purchase_price:null,
   cost_method:'manual',loan_price:1500,reorder_level:1}];
 state.data.purchases=[];state.data.suppliers=[{id:'supplier',name:'Supplier'}];
 _purLines=[{asset_id:'asset',asset_name:'Sofa',quantity:10,cost_per_unit:10500,landed_adjustment:0,subtotal:105000,batch_no:''}];
 ensureFreshToken=async()=>true;closeModal=()=>{};render=()=>{};audit=()=>{};
  toast=(message,kind)=>{globalThis.lastToast={message,kind};};
  modal=config=>{globalThis.assetModal=config;};
 globalThis.savedInventory=null;globalThis.savedLine=null;globalThis.savedLink=null;
 globalThis.savedReference=null;globalThis.referenceCallCount=0;globalThis.purchaseInsertCount=0;
 state._inventoryReferencePricesReady=true;
 sb.rpc=async(name,args)=>{
  if(name!=='pb_set_inventory_reference_prices') throw Error('Unexpected RPC '+name);
  globalThis.savedReference=args;globalThis.referenceCallCount++;
  return {data:[{id:args.p_inventory_id,purchase_price:args.p_purchase_price,buying_price:args.p_buying_price}],error:null};
 };
 sb.from=table=>({
  select(){return {limit:async()=>({error:null})};},
  insert(row){
   if(table==='pb_purchases'){globalThis.purchaseInsertCount++;
    return {select(){return {single:async()=>({data:{id:'purchase',...row},error:null})};}};}
   if(table==='pb_purchase_lines'){globalThis.savedLine=row;return Promise.resolve({error:null});}
   if(table==='pb_inventory') return {select(){return {single:async()=>({data:{id:'new-asset',...row},error:null})};}};
   throw Error('Unexpected inventory insertion');
  },
  update(row){
   if(table==='pb_purchase_lines') return {eq:async(key,id)=>{globalThis.savedLink={row,key,id};return {error:null};}};
   if(table!=='pb_inventory') throw Error('Unexpected update');
   return {eq:async()=>{globalThis.savedInventory=row;return {error:null};}};
  }
 });`);
(async()=>{
 await run('submitPurchase()');
 assert.deepEqual(JSON.parse(JSON.stringify(sandbox.savedInventory)),{
  stock:20
 },'receiving stock updates only the stock quantity');
 assert.equal(run(`state.data.inventory[0].loan_price`),14000);
 assert.equal(run(`state.data.inventory[0].purchase_price`),10000);
 assert.equal(run(`state.data.inventory[0].buying_price`),10000);
 assert.equal(sandbox.savedLine[0].cost_per_unit,10500);
 assert.equal(sandbox.savedLine[0].landed_adjustment,0);
 const fieldValues={name:'Sofa',category:'Furniture',stock:'20',purchase_price:'11000',buying_price:'10250',
  cost_method:'weighted_average',cost_adjustment:'0',loan_price:'14000',reorder_level:'2'};
 sandbox.assetFields=Object.entries(fieldValues);
 run(`openAssetForm(state.data.inventory[0]);`);
 await sandbox.assetModal.actions[1].onClick();
 assert.equal(sandbox.savedInventory.purchase_price,undefined,'protected price never goes through table update');
 assert.equal(sandbox.savedInventory.buying_price,undefined);
 assert.equal(sandbox.savedReference.p_purchase_price,11000);
 assert.equal(sandbox.savedReference.p_buying_price,10250,'changing wholesale price alone does not rewrite old stock cost');
 assert.equal(sandbox.savedInventory.loan_price,14000,'changing supplier price does not alter approved loan price');
 sandbox.assetFields=Object.entries({...fieldValues,purchase_price:'10500',cost_method:'latest_purchase',cost_adjustment:'500'});
 run(`openAssetForm(state.data.inventory[0]);`);
 await sandbox.assetModal.actions[1].onClick();
 assert.equal(sandbox.savedReference.p_buying_price,11000,'manager can explicitly set valuation from buying price and transport');
 assert.equal(sandbox.savedInventory.loan_price,14000);
 sandbox.assetFields=Object.entries({...fieldValues,cost_method:'manual',buying_price:'10000'});
 run(`openAssetForm(state.data.inventory[0]);`);
 await sandbox.assetModal.actions[1].onClick();
 assert.equal(sandbox.savedReference.p_buying_price,10000,'manual valuation remains independent');
 assert.equal(sandbox.savedReference.p_purchase_price,11000);
 assert.equal(sandbox.savedInventory.loan_price,14000);
 run(`state.staff.app_role='inventory_officer';`);
 const referenceCallsBefore=sandbox.referenceCallCount;
 sandbox.assetFields=Object.entries({...fieldValues,cost_method:'manual',buying_price:'10000',loan_price:'1',purchase_price:'11500'});
 run(`openAssetForm(state.data.inventory[0]);`);
 assert.doesNotMatch(sandbox.assetModal.body,/Actual buying \/ wholesale|Stock valuation cost\/unit/);
 await sandbox.assetModal.actions[1].onClick();
 assert.equal(sandbox.savedInventory.loan_price,undefined,'inventory staff cannot reprice a managed asset through the cost form');
 assert.equal(sandbox.savedInventory.purchase_price,undefined);
 assert.equal(sandbox.savedInventory.buying_price,undefined);
 assert.equal(sandbox.referenceCallCount,referenceCallsBefore,'inventory staff cannot call the management price updater');
 run(`state.view='inventory';pageInventory();`);
 assert.doesNotMatch(page.innerHTML,/Actual buying\/wholesale price|Stock valuation cost\/unit|KES 11,000|KES 10,000/);
 const procurementReport=JSON.parse(JSON.stringify(run(`buildReportRows('inventory')`)));
 assert.deepEqual(Object.keys(procurementReport[0]),['Name','Category','Qty','LoanPricePerUnit','TotalLoanValue']);
 run(`_purLines=[{asset_id:'',asset_name:'',isNew:false,quantity:2,cost_per_unit:1500,landed_adjustment:12,subtotal:3000,batch_no:''}];
  purSelectAsset(0,'asset','Sofa',false);`);
 assert.equal(run(`_purLines[0].cost_per_unit`),0,'asset selection never fetches confidential reference price');
 assert.equal(run(`_purLines[0].landed_adjustment`),0,'asset selection does not fetch a costing adjustment');
 run(`state.staff.app_role='admin';`);
 run(`state.view='inventory';pageInventory();`);
 assert.match(page.innerHTML,/Actual buying\/wholesale price/);
 assert.match(page.innerHTML,/Stock valuation cost\/unit/);
 assert.match(page.innerHTML,/Loan price\/unit/);
 assert.match(page.innerHTML,/KES 11,000/);
 assert.match(page.innerHTML,/KES 10,000/);
 assert.match(page.innerHTML,/KES 14,000/);
 const before=page.innerHTML;
 search.value='S';search.selectionStart=1;search.onInput({target:search});
 search.value='So';search.selectionStart=2;search.onInput({target:search});
 assert.equal(timers.size,1,'typing coalesces into one inventory render');
 assert.equal(page.innerHTML,before,'typing does not synchronously rebuild the entire page');
 [...timers.values()][0]();timers.clear();
 assert.match(page.innerHTML,/Sofa/);assert.doesNotMatch(page.innerHTML,/<b>Chair<\/b>/);
 assert.match(page.innerHTML,/KES 11,000/);
 // The previous loan search rebuilt the entire repayment index after each pause.
 run(`state.view='loans';state._invSearch='';state._loanTab='active';state._loanSearch='';
  state.data.members=[{id:'member',full_name:'Jane Client',group_id:'group',status:'active'}];
  state.data.groups=[{id:'group',name:'Group',officer_id:'manager'}];
  state.data.staff=[state.staff];
  state.data.loans=[{id:'loan',member_id:'member',group_id:'group',officer_id:'manager',
   status:'active',asset_name:'Sofa',loan_value:14000,total_payable:16000,weekly_installment:500,
   start_date:'2026-09-01'}];
  state._financialSnapshot={asOfDate:todayISO(),checkedAt:new Date().toISOString(),
   byLoan:new Map([['loan',{id:'loan',group_id:'group',officer_id:'manager',paid:0,outstandingPI:16000}]])};
  state._financialSnapshotAvailable=true;state._portfolioDataVerified=true;
  buildBalanceIndexes=()=>{throw Error('Name search must not rescan all repayment history');};
  pageLoans();`);
 assert.match(page.innerHTML,/Jane Client/);
 const unfilteredLoans=page.innerHTML;
 loanSearch.value='Jan';loanSearch.selectionStart=3;loanSearch.onInput({target:loanSearch});
 assert.equal(page.innerHTML,unfilteredLoans);
 [...timers.values()][0]();timers.clear();
 assert.match(page.innerHTML,/Jane Client/);
 // Member search keeps the same derived accounting index while letters are typed.
 let repaymentScans=0;
 sandbox.repaymentRows=[{member_id:'member'}];
 const originalForEach=sandbox.repaymentRows.forEach.bind(sandbox.repaymentRows);
 sandbox.repaymentRows.forEach=(callback)=>{repaymentScans++;return originalForEach(callback);};
 run(`state.view='members';state.data.savings=[];state.data.repayments=repaymentRows;
  state.data.orders=[];state.data.guarantors=[];state._memberSearch='';pageMembers();`);
 assert.equal(repaymentScans,1);
 sandbox.document.activeElement={id:'mem-search'};
 run(`state._memberSearch='Jane';pageMembers();`);
 assert.equal(repaymentScans,1,'one name query does not reprocess every repayment');
 // A typed name must never silently become a new item or retain the old asset ID.
 const purchasesBefore=sandbox.purchaseInsertCount;
 run(`_purLines=[{asset_id:'asset',asset_name:'Sofa',isNew:false,quantity:12,
  cost_per_unit:1500,landed_adjustment:0,subtotal:18000,batch_no:''}];
  purAssetInput(0,'Laptop bag medium');`);
 assert.equal(run(`_purLines[0].asset_id`),'');
 assert.equal(run(`_purLines[0].isNew`),false);
 await run(`submitPurchase()`);
 assert.equal(sandbox.purchaseInsertCount,purchasesBefore,'unselected typed name creates no purchase');
 assert.match(sandbox.lastToast.message,/Select each listed asset/);
 // Choosing Add New makes the intent explicit and links the resulting asset to its line.
 run(`purSelectAsset(0,'','Laptop bag medium',true);
  _purLines[0].cost_per_unit=1500;_purLines[0].landed_adjustment=40;
  _purLines[0].subtotal=18000;`);
 await run(`submitPurchase()`);
 assert.equal(sandbox.purchaseInsertCount,purchasesBefore+1);
 assert.equal(sandbox.savedLine[0].asset_id,null);
 assert.equal(sandbox.savedLink.id,sandbox.savedLine[0].id);
 assert.equal(sandbox.savedLink.row.asset_id,'new-asset');
 assert.equal(run(`state.data.inventory[0].loan_price`),0,'new stock receives no automatic selling price');
 assert.equal(run(`state.data.inventory[0].purchase_price`),undefined,'purchase price remains management-only');
 assert.equal(run(`state.data.inventory[0].buying_price`),undefined,'valuation cost remains management-only');
 console.log('Inventory reference price separation, stock receipts and debounced name search passed.');
})().catch(error=>{console.error(error);process.exitCode=1;});
