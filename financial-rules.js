/* Shared date and money rules for dashboards, loan balances and exports. */
(function(root){
  'use strict';
  const dateMs=value=>Date.parse(`${String(value||'').slice(0,10)}T00:00:00Z`);
  const dayMs=86400000;
  const money=value=>Math.round((Number(value||0)+Number.EPSILON)*100)/100;
  const approved=row=>!!row && !row.voided_at &&
    !['pending','rejected','cancelled','voided'].includes(String(row.status||'approved').toLowerCase());
  function paymentDate(row){
    if(row.meeting_date) return String(row.meeting_date).slice(0,10);
    const date=new Date(row.created_at);
    if(!row.created_at || !Number.isFinite(date.getTime())) return null;
    const parts=new Intl.DateTimeFormat('en-CA',{timeZone:'Africa/Nairobi',year:'numeric',month:'2-digit',day:'2-digit'}).formatToParts(date);
    const pick=type=>parts.find(part=>part.type===type)?.value;
    return `${pick('year')}-${pick('month')}-${pick('day')}`;
  }
  function expected(loan,asOf,includeToday=true){
    const days=Math.floor((dateMs(asOf)-dateMs(loan.start_date))/dayMs);
    if(!Number.isFinite(days) || days<0) return 0;
    // start_date is the first instalment due date, as in the deposit-release ledger.
    const count=includeToday?Math.floor(days/7)+1:Math.ceil(days/7);
    return money(Math.min(Number(loan.total_payable||0),count*Number(loan.weekly_installment||0)));
  }
  function metrics(loan,repayments,asOf){
    const rows=(repayments||[]).filter(r=>String(r.loan_id)===String(loan.id) && approved(r) && paymentDate(r) && paymentDate(r)<=asOf);
    const paid=money(rows.reduce((sum,r)=>sum+Number(r.amount||0),0));
    const clientRows=rows.filter(r=>!String(r.notes||'').startsWith('Auto-deducted'));
    const principalPaid=money(clientRows.reduce((sum,r)=>sum+Number(r.principal||0),0));
    const interestPaid=money(clientRows.reduce((sum,r)=>sum+Number(r.interest||0),0));
    const weekly=Number(loan.weekly_installment||0),total=Number(loan.total_payable||0);
    const days=Math.floor((dateMs(asOf)-dateMs(loan.start_date))/dayMs);
    const last=Math.max(0,Math.ceil(total/weekly)-1);
    const next=Math.min(last,Math.max(0,Math.ceil(days/7)));
    const nextDueDate=weekly>0 && Number.isFinite(days) && total>paid
      ?new Date(dateMs(loan.start_date)+next*7*dayMs).toISOString().slice(0,10):null;
    return {paid,principalPaid,interestPaid,totalPayable:total,principal:Number(loan.loan_value||0),
      outstandingPI:money(Math.max(0,total-paid)),
      outstandingPrincipal:money(Math.max(0,Number(loan.loan_value||0)-principalPaid)),
      expectedInterest:money(Math.max(0,total-Number(loan.loan_value||0))),
      amountDue:money(Math.max(0,expected(loan,asOf)-paid)),
      arrears:money(Math.max(0,expected(loan,asOf,false)-paid-5)),nextDueDate};
  }
  const rules={approved,paymentDate,expected,metrics,money};
  root.WamamaFinance=rules;
  if(typeof module==='object' && module.exports) module.exports=rules;
})(typeof globalThis==='object'?globalThis:this);
