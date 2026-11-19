/* EDMEL Expenses & Profit — Phase 2: Supabase-backed Operating Expenses */
(() => {
'use strict';
const PAGE_LIMIT=2000;
let cats=[],branches=[],expenses=[],currency='USD',loading=false,loadError='';
const today=()=>{const d=new Date();return `${d.getFullYear()}-${String(d.getMonth()+1).padStart(2,'0')}-${String(d.getDate()).padStart(2,'0')}`};
const escE=v=>esc(String(v??''));
const money=v=>{try{return new Intl.NumberFormat('en-US',{style:'currency',currency}).format(Number(v)||0)}catch(_){return currency+' '+(Number(v)||0).toFixed(2)}};
const branchName=id=>branches.find(x=>x.id===id)?.name||(id?'Unlisted branch':'Unassigned');
const catName=id=>cats.find(x=>x.id===id)?.name||'Unavailable category';
const dateText=v=>v?new Date(String(v).slice(0,10)+'T00:00:00').toLocaleDateString('en-US',{year:'numeric',month:'short',day:'numeric'}):'—';
const statusText={pending:'Pending approval',approved:'Approved',rejected:'Rejected',voided:'Voided'};
const statusBadge=s=>`<span class="bd ${s==='approved'?'ok':s==='pending'?'wn':s==='rejected'?'er':''}">${statusText[s]||'Unknown'}</span>`;

async function loadExpenses(){
 if(!CURRENT_RESTAURANT_ID){loadError='Restaurant access could not be verified.';expenses=[];if(S.page==='exp')render();return}
 loading=true;loadError='';if(S.page==='exp')render();
 try{
  const [c,b,e,r]=await Promise.all([
   sb.from('restaurant_expense_categories').select('id,name,description,is_active').eq('restaurant_id',CURRENT_RESTAURANT_ID).order('name'),
   sb.from('restaurant_branches').select('id,name,code,is_default').eq('restaurant_id',CURRENT_RESTAURANT_ID).eq('is_active',true).order('name'),
   sb.from('restaurant_expenses').select('id,restaurant_id,branch_id,category_id,expense_date,description,payee,reference_number,notes,amount,currency_code,status,created_at,approved_at,approval_note,rejection_reason,void_reason').eq('restaurant_id',CURRENT_RESTAURANT_ID).order('expense_date',{ascending:false}).order('created_at',{ascending:false}).limit(PAGE_LIMIT),
   sb.from('restaurants').select('currency').eq('id',CURRENT_RESTAURANT_ID).maybeSingle()
  ]);
  if(c.error)throw c.error;if(b.error)throw b.error;if(e.error)throw e.error;if(r.error)throw r.error;
  cats=c.data||[];branches=b.data||[];expenses=e.data||[];currency=String(r.data?.currency||'USD').toUpperCase();
  if(!/^[A-Z]{3}$/.test(currency))currency='USD';
  if(S.f.expBranch&&!branches.some(x=>x.id===S.f.expBranch))S.f.expBranch='';
  if(S.f.expCategory&&!cats.some(x=>x.id===S.f.expCategory))S.f.expCategory='';
 }catch(e){loadError=e?.message||String(e)}
 finally{loading=false;if(S.page==='exp')render()}
}

function expensePage(){
 const q=String(S.f.expQ||'').toLowerCase(),br=S.f.expBranch||'',cat=S.f.expCategory||'',st=S.f.expStatus||'';
 const rows=expenses.filter(x=>(!q||[x.description,x.payee,x.reference_number,catName(x.category_id),branchName(x.branch_id)].join(' ').toLowerCase().includes(q))&&(!br||x.branch_id===br)&&(!cat||x.category_id===cat)&&(!st||x.status===st));
 const approved=rows.filter(x=>x.status==='approved').reduce((n,x)=>n+Number(x.amount||0),0);
 const pending=rows.filter(x=>x.status==='pending');
 const month=today().slice(0,7),monthly=rows.filter(x=>x.status==='approved'&&String(x.expense_date).startsWith(month)).reduce((n,x)=>n+Number(x.amount||0),0);
 const options=(list,selected,all)=>`<option value="">${all}</option>`+list.map(x=>`<option value="${escE(x.id)}"${selected===x.id?' selected':''}>${escE(x.name)}</option>`).join('');
 const trs=rows.map(x=>{
  const acts=[`<button class="btn" data-a="expdetail" data-id="${x.id}">View</button>`];
  if(!['rejected','voided'].includes(x.status))acts.push(`<button class="btn" data-a="expedit" data-id="${x.id}">Edit</button>`);
  if(x.status==='pending')acts.push(`<button class="btn pri" data-a="expapprove" data-id="${x.id}">Approve</button><button class="btn" data-a="expreject" data-id="${x.id}">Reject</button>`);
  if(!['rejected','voided'].includes(x.status))acts.push(`<button class="btn danger" data-a="expvoid" data-id="${x.id}">Void</button>`);
  return `<tr><td>${dateText(x.expense_date)}</td><td>${escE(branchName(x.branch_id))}</td><td>${escE(catName(x.category_id))}</td><td><b>${escE(x.description)}</b>${x.payee?`<small class="mu" style="display:block">Payee: ${escE(x.payee)}</small>`:''}${x.reference_number?`<small class="mu" style="display:block">Ref: ${escE(x.reference_number)}</small>`:''}</td><td>${money(x.amount)}</td><td>${statusBadge(x.status)}</td><td><div style="display:flex;gap:5px;flex-wrap:wrap">${acts.join('')}</div></td></tr>`;
 }).join('');
 return `<div class="expense-p2">
 <div class="tb"><div><b>Operating Expenses</b><div class="note" style="margin:2px 0 0">Live restaurant records · ${currency}</div></div><span class="sp"></span><button class="btn" data-a="expcats">Manage Categories</button><button class="btn" data-a="exprefresh">Refresh</button><button class="btn pri" data-a="addexp">+ Add Expense</button></div>
 ${loadError?`<div class="card"><span class="bd er">● Expenses could not load</span><p>${escE(loadError)}</p><button class="btn" data-a="exprefresh">Try again</button></div>`:''}
 ${loading?'<div class="card"><p class="mu">Loading expense records…</p></div>':''}
 <div class="g k"><div class="card"><div class="mu">Approved Expenses</div><div class="big">${money(approved)}</div><small class="mu">Filtered records</small></div><div class="card"><div class="mu">Pending Approval</div><div class="big">${pending.length}</div><small class="mu">${money(pending.reduce((n,x)=>n+Number(x.amount||0),0))} awaiting review</small></div><div class="card"><div class="mu">Approved This Month</div><div class="big">${money(monthly)}</div><small class="mu">${month}</small></div></div>
 <section class="card"><div class="expense-filters">
 <label>Branch<select data-c="expBranch">${options(branches,br,'All accessible branches')}</select></label>
 <label>Category<select data-c="expCategory">${options(cats,cat,'All categories')}</select></label>
 <label>Status<select data-c="expStatus"><option value="">All statuses</option>${Object.entries(statusText).map(([k,v])=>`<option value="${k}"${st===k?' selected':''}>${v}</option>`).join('')}</select></label>
 <label>Search<input data-c="expQ" value="${escE(S.f.expQ||'')}" placeholder="Description, payee or reference"></label>
 </div></section>
 <section class="card"><div class="row"><h3 style="margin:0">Expense Records</h3><span class="mu">${rows.length} shown · ${expenses.length} loaded</span></div><div class="tw"><table class="inv-table"><thead><tr><th>Date</th><th>Branch</th><th>Category</th><th>Description</th><th>Amount</th><th>Status</th><th>Actions</th></tr></thead><tbody>${trs||`<tr><td colspan="7"><div class="empty">${cats.some(x=>x.is_active)?'No expense records match these filters.':'No active expense categories. Create a category before adding an expense.'}</div></td></tr>`}</tbody></table></div></section>
 <p class="note">Only approved operating expenses are included in approved expense totals. Pending, rejected and voided records remain available for review. Supplier purchases and profit calculations are separate future phases.</p></div>`;
}

function categoryModal(){
 const list=cats.map(x=>`<div class="row"><div style="flex:1"><b>${escE(x.name)}</b>${x.description?`<small class="mu" style="display:block">${escE(x.description)}</small>`:''}</div>${x.is_active?'<span class="bd ok">Active</span>':'<span class="bd">Inactive</span>'}<button class="btn" data-a="expcattoggle" data-id="${x.id}">${x.is_active?'Deactivate':'Activate'}</button></div>`).join('');
 L.innerHTML=`<div class="bk" data-a="close"></div><div class="md" role="dialog" aria-modal="true" aria-label="Expense categories"><div class="row"><h3 style="margin:0">Expense Categories</h3><button class="btn" data-a="close">Close</button></div><p class="note">Deactivate categories instead of deleting them to preserve historical expense records.</p><form id="expenseCatForm"><div class="fl"><label for="expenseCatName">Category Name *</label><input id="expenseCatName" required maxlength="80"></div><div class="fl"><label for="expenseCatDesc">Description</label><textarea id="expenseCatDesc" rows="2" maxlength="500"></textarea></div><button class="btn pri" id="expenseCatSave">Add Category</button><p id="expenseCatError" class="er"></p></form><h3 style="margin-top:16px">Saved Categories</h3>${list||'<div class="empty">No categories created yet.</div>'}</div>`;
 document.getElementById('expenseCatForm').onsubmit=async ev=>{
  ev.preventDefault();const btn=document.getElementById('expenseCatSave'),err=document.getElementById('expenseCatError');
  const name=document.getElementById('expenseCatName').value.trim(),description=document.getElementById('expenseCatDesc').value.trim();
  if(name.length<2){err.textContent='Category name must contain at least 2 characters.';return}
  btn.disabled=true;btn.textContent='Saving…';
  try{const {error}=await sb.from('restaurant_expense_categories').insert({restaurant_id:CURRENT_RESTAURANT_ID,name,description:description||null,is_active:true});if(error)throw error;await loadExpenses();categoryModal();toast('Expense category created.')}
  catch(e){err.textContent=e?.message||'Could not save category.';btn.disabled=false;btn.textContent='Add Category'}
 };
}

function expenseForm(row){
 if(!branches.length){toast('No active branch is available for expense recording.',1);return}
 if(row&&!cats.some(x=>x.id===row.category_id&&x.is_active)){toast('Reactivate this expense category before editing the record.',1);return}
 const active=cats.filter(x=>x.is_active);
 if(!active.length){categoryModal();toast('Create an expense category first.');return}
 const editing=!!row,defaultBranch=row?.branch_id||branches.find(x=>x.is_default)?.id||branches[0].id;
 L.innerHTML=`<div class="bk" data-a="close"></div><form id="expenseForm" class="md" role="dialog" aria-modal="true" aria-label="${editing?'Edit':'Add'} operating expense">
 <h3>${editing?'Edit Operating Expense':'Add Operating Expense'}</h3><p class="note">${editing?'Changes are saved with a required reason and audit history.':'The server determines whether this expense is pending or automatically approved.'}</p>
 <div class="fl"><label for="expenseBranch">Branch *</label><select id="expenseBranch" ${editing?'disabled':''}>${branches.map(x=>`<option value="${x.id}"${x.id===defaultBranch?' selected':''}>${escE(x.name)}</option>`).join('')}</select></div>
 <div class="fl"><label for="expenseCategory">Category *</label><select id="expenseCategory">${active.map(x=>`<option value="${x.id}"${x.id===row?.category_id?' selected':''}>${escE(x.name)}</option>`).join('')}</select></div>
 <div class="fl"><label for="expenseDate">Expense Date *</label><input id="expenseDate" type="date" required value="${escE(row?.expense_date||today())}"></div>
 <div class="fl"><label for="expenseDescription">Description *</label><input id="expenseDescription" required maxlength="500" value="${escE(row?.description||'')}" placeholder="What was this expense for?"></div>
 <div class="fl"><label for="expenseAmount">Amount (${currency}) *</label><input id="expenseAmount" type="number" min="0.01" step="0.01" required value="${row?Number(row.amount).toFixed(2):''}"></div>
 <div class="fl"><label for="expensePayee">Payee / Supplier</label><input id="expensePayee" maxlength="160" value="${escE(row?.payee||'')}"></div>
 <div class="fl"><label for="expenseRef">Reference Number</label><input id="expenseRef" maxlength="120" value="${escE(row?.reference_number||'')}"></div>
 <div class="fl"><label for="expenseNotes">Notes</label><textarea id="expenseNotes" maxlength="2000" rows="2">${escE(row?.notes||'')}</textarea></div>
 ${editing?'<div class="fl"><label for="expenseReason">Reason for Change *</label><textarea id="expenseReason" minlength="3" maxlength="500" required rows="2"></textarea></div>':''}
 <div class="tb"><button class="btn pri" id="expenseSave">${editing?'Save Changes':'Save Expense'}</button><button class="btn" type="button" data-a="close">Cancel</button></div><p id="expenseError" class="er"></p></form>`;
 document.getElementById('expenseForm').onsubmit=async ev=>{
  ev.preventDefault();const btn=document.getElementById('expenseSave'),err=document.getElementById('expenseError');
  const p={p_category_id:document.getElementById('expenseCategory').value,p_expense_date:document.getElementById('expenseDate').value,p_description:document.getElementById('expenseDescription').value.trim(),p_amount:Number(document.getElementById('expenseAmount').value),p_payee:document.getElementById('expensePayee').value.trim()||null,p_reference_number:document.getElementById('expenseRef').value.trim()||null,p_notes:document.getElementById('expenseNotes').value.trim()||null};
  if(!p.p_description||!p.p_expense_date||!p.p_category_id||!Number.isFinite(p.p_amount)||p.p_amount<=0){err.textContent='Complete the required fields and enter an amount greater than zero.';return}
  btn.disabled=true;btn.textContent='Saving…';
  try{
   let result;
   if(editing){const reason=document.getElementById('expenseReason').value.trim();if(reason.length<3)throw new Error('Enter a reason for this change.');result=await sb.rpc('edmel_update_operating_expense',{p_expense_id:row.id,...p,p_reason:reason})}
   else result=await sb.rpc('edmel_create_operating_expense',{p_restaurant_id:CURRENT_RESTAURANT_ID,p_branch_id:document.getElementById('expenseBranch').value,...p});
   if(result.error)throw result.error;closeL();await loadExpenses();toast(editing?'Expense updated. Audit history recorded.':'Expense saved. Approval status was assigned by the server.');
  }catch(e){err.textContent=e?.message||'Could not save expense.';btn.disabled=false;btn.textContent=editing?'Save Changes':'Save Expense'}
 };
}

function decisionModal(id,decision){
 const labels={approved:'Approve Expense',rejected:'Reject Expense',voided:'Void Expense'};
 const help={approved:'Add an approval note or reason.',rejected:'Explain why this expense is being rejected.',voided:'Explain why this expense is being voided.'};
 L.innerHTML=`<div class="bk" data-a="close"></div><form id="expenseDecisionForm" class="md" role="dialog" aria-modal="true" aria-label="${labels[decision]}"><h3>${labels[decision]}</h3><p class="note">${help[decision]}</p><div class="fl"><label for="expenseDecisionReason">Reason *</label><textarea id="expenseDecisionReason" minlength="3" maxlength="500" rows="3" required></textarea></div><div class="tb"><button class="btn pri" id="expenseDecisionSave">Confirm</button><button class="btn" type="button" data-a="close">Cancel</button></div><p id="expenseDecisionError" class="er"></p></form>`;
 document.getElementById('expenseDecisionForm').onsubmit=async ev=>{
  ev.preventDefault();const reason=document.getElementById('expenseDecisionReason').value.trim(),btn=document.getElementById('expenseDecisionSave'),err=document.getElementById('expenseDecisionError');
  if(reason.length<3){err.textContent='Enter a reason with at least 3 characters.';return}
  btn.disabled=true;btn.textContent='Processing…';
  try{const result=decision==='voided'?await sb.rpc('edmel_void_operating_expense',{p_expense_id:id,p_reason:reason}):await sb.rpc('edmel_review_operating_expense',{p_expense_id:id,p_decision:decision,p_reason:reason});if(result.error)throw result.error;closeL();await loadExpenses();toast(labels[decision]+' completed. Audit history recorded.')}
  catch(e){err.textContent=e?.message||'The action could not be completed.';btn.disabled=false;btn.textContent='Confirm'}
 };
}

function expenseDetail(id){
 const x=expenses.find(e=>e.id===id);if(!x)return;
 const fields=[['Date',dateText(x.expense_date)],['Branch',branchName(x.branch_id)],['Category',catName(x.category_id)],['Description',x.description],['Amount',money(x.amount)],['Status',statusText[x.status]||x.status],['Payee',x.payee||'—'],['Reference',x.reference_number||'—'],['Notes',x.notes||'—'],['Approval note',x.approval_note||'—'],['Rejection reason',x.rejection_reason||'—'],['Void reason',x.void_reason||'—']];
 L.innerHTML=`<div class="bk" data-a="close"></div><div class="md" role="dialog" aria-modal="true" aria-label="Expense details"><div class="row"><h3 style="margin:0">Expense Details</h3><button class="btn" data-a="close">Close</button></div>${fields.map(([a,b])=>`<div class="row"><span class="mu">${a}</span><b style="text-align:right;overflow-wrap:anywhere">${escE(b)}</b></div>`).join('')}<div class="tb" style="margin-top:12px">${x.status==='pending'?`<button class="btn pri" data-a="expapprove" data-id="${id}">Approve</button><button class="btn" data-a="expreject" data-id="${id}">Reject</button>`:''}${!['rejected','voided'].includes(x.status)?`<button class="btn" data-a="expedit" data-id="${id}">Edit</button><button class="btn danger" data-a="expvoid" data-id="${id}">Void</button>`:''}</div></div>`;
}

async function toggleCategory(id){
 const x=cats.find(c=>c.id===id);if(!x)return;const active=!x.is_active;
 if(!confirm((active?'Activate':'Deactivate')+' category "'+x.name+'"?'))return;
 try{const {error}=await sb.from('restaurant_expense_categories').update({is_active:active}).eq('id',id).eq('restaurant_id',CURRENT_RESTAURANT_ID);if(error)throw error;await loadExpenses();categoryModal();toast('Category status updated.')}
 catch(e){toast('Could not update category: '+(e?.message||String(e)),1)}
}

PG.exp=expensePage;
A.addexp=()=>expenseForm(null);
A.expcats=()=>categoryModal();
A.expcattoggle=t=>toggleCategory(t.dataset.id);
A.exprefresh=()=>loadExpenses();
A.expedit=t=>{const x=expenses.find(e=>e.id===t.dataset.id);if(x)expenseForm(x);else toast('Expense record not found.',1)};
A.expdetail=t=>expenseDetail(t.dataset.id);
A.expapprove=t=>decisionModal(t.dataset.id,'approved');
A.expreject=t=>decisionModal(t.dataset.id,'rejected');
A.expvoid=t=>decisionModal(t.dataset.id,'voided');
const oldGo=A.go;
A.go=t=>{const page=t?.dataset?.p;oldGo(t);if(page==='exp')loadExpenses()};
document.addEventListener('input',ev=>{
 const t=ev.target;if(t?.dataset?.c!=='expQ')return;
 S.f.expQ=t.value;const pos=t.selectionStart;render();const next=document.querySelector('#pg [data-c="expQ"]');if(next){next.focus();next.setSelectionRange(pos,pos)}
});
const css=document.createElement('style');css.id='edmel-expense-phase2-css';css.textContent=`
.expense-p2{display:grid;gap:14px}.expense-filters{display:grid;grid-template-columns:repeat(4,minmax(130px,1fr));gap:12px}
.expense-filters label{display:grid;gap:5px;color:var(--mu);font-size:12px;font-weight:600}
.expense-filters input,.expense-filters select{width:100%;min-width:0}
@media(max-width:760px){.expense-filters{grid-template-columns:repeat(2,minmax(0,1fr))}}
@media(max-width:480px){.expense-filters{grid-template-columns:1fr}}
`;document.head.appendChild(css);
if(S.page==='exp')loadExpenses();
})();
