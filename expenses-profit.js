/* EDMEL Expenses & Profit — Phase 2: Supabase-backed Operating Expenses */
(() => {
'use strict';
const PAGE_LIMIT=2000;
let cats=[],branches=[],expenses=[],managerRequests=[],managerUsers=[],managerExpenseNotifications=[],currency='USD',loading=false,loadError='';
let selectedManagerRequestIds=new Set(),managerRequestSelectionBranch='';
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
  const [c,b,e,r,mr,mu,n,pol,em,emn,audit]=await Promise.all([
   sb.from('restaurant_expense_categories').select('id,name,description,is_active').eq('restaurant_id',CURRENT_RESTAURANT_ID).order('name'),
   sb.from('restaurant_branches').select('id,name,code,is_default').eq('restaurant_id',CURRENT_RESTAURANT_ID).eq('is_active',true).order('name'),
   sb.from('restaurant_expenses').select('id,restaurant_id,branch_id,category_id,expense_date,description,payee,reference_number,notes,amount,currency_code,status,created_at,approved_at,approval_note,rejection_reason,void_reason').eq('restaurant_id',CURRENT_RESTAURANT_ID).order('expense_date',{ascending:false}).order('created_at',{ascending:false}).limit(PAGE_LIMIT),
   sb.from('restaurants').select('currency,timezone').eq('id',CURRENT_RESTAURANT_ID).maybeSingle(),
   sb.from('manager_expense_requests').select('id,branch_id,manager_restaurant_user_id,submitted_by_user_id,request_type,expense_id,request_data,status,submitted_at,reviewed_at,review_reason').eq('restaurant_id',CURRENT_RESTAURANT_ID).order('submitted_at',{ascending:false}).limit(500),
   sb.from('restaurant_users').select('id,display_name,full_name,cashier_username,position').eq('restaurant_id',CURRENT_RESTAURANT_ID),
   sb.from('manager_expense_request_notifications').select('id,branch_id,request_id,title,message,created_at').eq('restaurant_id',CURRENT_RESTAURANT_ID).eq('recipient_role','admin').eq('is_read',false).order('created_at',{ascending:false}).limit(50),
   sb.from('restaurant_expense_policies').select('restaurant_id,branch_id,create_approval_mode,edit_approval_mode,void_approval_mode,emergency_authorization_limit,updated_at').eq('restaurant_id',CURRENT_RESTAURANT_ID),
   sb.from('manager_emergency_authorization_requests').select('*').eq('restaurant_id',CURRENT_RESTAURANT_ID).order('created_at',{ascending:false}).limit(500),
   sb.from('manager_emergency_authorization_notifications').select('id,branch_id,request_id,title,message,created_at').eq('restaurant_id',CURRENT_RESTAURANT_ID).eq('recipient_role','admin').eq('is_read',false).order('created_at',{ascending:false}).limit(50),
   sb.from('restaurant_expense_audit_logs').select('id,branch_id,record_type,record_id,action,actor_name,actor_role,permission_key,reason,before_data,after_data,created_at').eq('restaurant_id',CURRENT_RESTAURANT_ID).order('created_at',{ascending:false}).limit(500)
  ]);
  if(c.error)throw c.error;if(b.error)throw b.error;if(e.error)throw e.error;if(r.error)throw r.error;if(mr.error)throw mr.error;if(mu.error)throw mu.error;if(n.error)throw n.error;
  if(pol.error)throw pol.error;if(em.error)throw em.error;if(emn.error)throw emn.error;if(audit.error)throw audit.error;
  cats=c.data||[];branches=b.data||[];expenses=e.data||[];managerRequests=mr.data||[];managerUsers=mu.data||[];managerExpenseNotifications=n.data||[];
  expensePolicies=pol.data||[];emergencyRequests=em.data||[];emergencyNotifications=emn.data||[];expenseAuditRows=audit.data||[];restaurantTimezone=String(r.data?.timezone||'UTC');
  const expenseDot=document.querySelector('#dot');if(expenseDot)expenseDot.style.display=(managerExpenseNotifications.length||emergencyNotifications.length||((typeof NT!=='undefined')&&NT.some(x=>!x.r)))?'block':'none';
  currency=String(r.data?.currency||'USD').toUpperCase();
  if(!/^[A-Z]{3}$/.test(currency))currency='USD';
  if(S.f.expBranch&&!branches.some(x=>x.id===S.f.expBranch))S.f.expBranch='';
  if(S.f.expCategory&&!cats.some(x=>x.id===S.f.expCategory))S.f.expCategory='';
 }catch(e){loadError=e?.message||String(e)}
 finally{loading=false;if(S.page==='exp')render()}
}

function expensePage(){
 const q=String(S.f.expQ||'').toLowerCase(),br=S.f.expBranch||'',cat=S.f.expCategory||'',st=S.f.expStatus||'';
 if(br!==managerRequestSelectionBranch){selectedManagerRequestIds.clear();managerRequestSelectionBranch=br;}
 const visibleRequests=managerRequests.filter(x=>!br||x.branch_id===br);
 const pendingManagerRequests=visibleRequests.filter(x=>x.status==='pending');
 const selectedPendingCount=pendingManagerRequests.filter(x=>selectedManagerRequestIds.has(x.id)).length;
 const notificationHtml=managerExpenseNotifications.length?'<div class="card" style="margin:10px 0;padding:12px"><div class="row"><strong>New Manager Expense Notifications</strong><span class="mu">'+managerExpenseNotifications.length+' unread</span></div>'+managerExpenseNotifications.map(n=>'<div class="row" style="gap:10px;padding:8px 0;border-top:1px solid var(--line)"><div style="flex:1;min-width:0"><strong>'+escE(n.title)+'</strong><small class="mu" style="display:block">'+escE(n.message)+' · '+dateText(n.created_at)+'</small></div><button class="btn" data-a="managerexpmarkread" data-id="'+escE(n.id)+'">Mark read</button></div>').join('')+'</div>':'';
 const bulkToolbar=br?'<div class="tb" style="gap:8px;flex-wrap:wrap;margin:10px 0"><span class="mu">'+selectedPendingCount+' selected · '+pendingManagerRequests.length+' pending in this branch</span><button class="btn" data-a="managerexpselectpending" '+(!pendingManagerRequests.length?'disabled':'')+'>Select Pending</button><button class="btn" data-a="managerexpclearselection" '+(!selectedManagerRequestIds.size?'disabled':'')+'>Clear Selection</button><button class="btn pri" data-a="managerexpbulkapprove" '+(!selectedPendingCount?'disabled':'')+'>Approve Selected</button><button class="btn" data-a="managerexpbulkreject" '+(!selectedPendingCount?'disabled':'')+'>Reject Selected</button></div>':'<p class="note" style="margin:10px 0">Select a branch in the filter above to enable branch-scoped bulk review.</p>';
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
 <section class="card"><div class="row"><h3 style="margin:0">Manager Approval Requests</h3><span class="mu">${pendingManagerRequests.length} pending · ${visibleRequests.length} shown</span></div>${notificationHtml}${bulkToolbar}<p class="note">Manager submissions are held separately until an authorized reviewer approves them. Bulk review is limited to the selected branch. Rejecting a request does not alter the official expense record.</p><div class="tw"><table class="inv-table"><thead><tr><th>Select</th><th>Submitted</th><th>Branch</th><th>Manager</th><th>Request</th><th>Description</th><th>Amount</th><th>Status</th><th>Actions</th></tr></thead><tbody>${visibleRequests.map(req=>{const data=req.request_data||{},row=expenses.find(x=>x.id===req.expense_id),manager=managerUsers.find(x=>x.id===req.manager_restaurant_user_id),name=manager?.display_name||manager?.full_name||manager?.cashier_username||'Manager',description=req.request_type==='create'?(data.description||'New expense'):req.request_type==='edit'?(data.description||row?.description||'Expense edit'):(row?.description||'Expense void'),amount=req.request_type==='void'?row?.amount:data.amount,selectCell=req.status==='pending'?'<input type="checkbox" data-manager-expense-request-select data-id="'+req.id+'" '+(selectedManagerRequestIds.has(req.id)?'checked':'')+' aria-label="Select expense request">':'—',actions=req.status==='pending'?'<button class="btn pri" data-a="managerexprequestapprove" data-id="'+req.id+'">Approve</button><button class="btn" data-a="managerexprequestreject" data-id="'+req.id+'">Reject</button>':'<span class="mu">Reviewed</span>';return '<tr><td>'+selectCell+'</td><td>'+dateText(req.submitted_at)+'</td><td>'+escE(branchName(req.branch_id))+'</td><td>'+escE(name)+'</td><td>'+escE(req.request_type.charAt(0).toUpperCase()+req.request_type.slice(1))+'</td><td><b>'+escE(description)+'</b></td><td>'+(amount==null?'—':money(amount))+'</td><td>'+statusBadge(req.status)+'</td><td><div style="display:flex;gap:5px;flex-wrap:wrap">'+actions+'</div></td></tr>'}).join('') || '<tr><td colspan="9"><div class="empty">No Manager expense requests have been submitted for this branch filter.</div></td></tr>'}</tbody></table></div></section>
 <section class="card"><div class="row"><h3 style="margin:0">Expense Records</h3><span class="mu">${rows.length} shown · ${expenses.length} loaded</span></div><div class="tw"><table class="inv-table"><thead><tr><th>Date</th><th>Branch</th><th>Category</th><th>Description</th><th>Amount</th><th>Status</th><th>Actions</th></tr></thead><tbody>${trs||`<tr><td colspan="7"><div class="empty">${cats.some(x=>x.is_active)?'No expense records match these filters.':'No active expense categories. Create a category before adding an expense.'}</div></td></tr>`}</tbody></table></div></section>
 <p class="note">Only approved operating expenses are included in approved expense totals. Pending, rejected and voided records remain available for review. Supplier purchases and profit calculations are separate future phases.</p></div>`;
}

function managerExpenseBulkDecisionModal(decision){
 const ids=Array.from(selectedManagerRequestIds),branchId=S.f.expBranch||'';
 if(!branchId){toast('Select one branch before using bulk review.',1);return}
 if(!ids.length||ids.length>50){toast('Select between 1 and 50 pending requests.',1);return}
 const selected=managerRequests.filter(r=>ids.includes(r.id)&&r.branch_id===branchId&&r.status==='pending');
 if(selected.length!==ids.length){selectedManagerRequestIds.clear();toast('The selection changed. Refresh the requests and try again.',1);render();return}
 const label=decision==='approved'?'Approve Selected Requests':'Reject Selected Requests';
 L.innerHTML='<div class="bk" data-a="close"></div><form class="md" role="dialog" aria-modal="true" aria-label="'+label+'" id="managerExpenseBulkDecisionForm"><h3>'+label+'</h3><p class="note">This action applies to '+ids.length+' pending request(s) in '+escE(branchName(branchId))+'. All selected requests will be processed together. If one request fails validation, none will be changed.</p><div class="fl"><label for="managerExpenseBulkReason">Review reason *</label><textarea id="managerExpenseBulkReason" minlength="3" maxlength="500" rows="3" required></textarea></div><div class="tb"><button class="btn pri" id="managerExpenseBulkSave">Confirm</button><button class="btn" type="button" data-a="close">Cancel</button></div><p id="managerExpenseBulkError" class="er"></p></form>';
 document.getElementById('managerExpenseBulkDecisionForm').onsubmit=async ev=>{
  ev.preventDefault();const reason=document.getElementById('managerExpenseBulkReason').value.trim(),btn=document.getElementById('managerExpenseBulkSave'),err=document.getElementById('managerExpenseBulkError');
  if(reason.length<3){err.textContent='Enter a reason with at least 3 characters.';return}
  btn.disabled=true;btn.textContent='Processing…';
  try{const result=await sb.rpc('edmel_review_manager_expense_requests_bulk',{p_restaurant_id:CURRENT_RESTAURANT_ID,p_branch_id:branchId,p_request_ids:ids,p_decision:decision,p_reason:reason});if(result.error)throw result.error;if(!result.data?.success||Number(result.data.processed_count)!==ids.length)throw new Error('The bulk decision was not fully confirmed.');selectedManagerRequestIds.clear();closeL();await loadExpenses();toast(ids.length+' Manager expense request(s) '+(decision==='approved'?'approved.':'rejected.'))}
  catch(e){err.textContent=e?.message||'Unable to process the selected requests.';btn.disabled=false;btn.textContent='Confirm'}
 };
}
function managerExpenseRequestDecisionModal(id,decision){
 const request=managerRequests.find(x=>x.id===id);if(!request||request.status!=='pending')return;
 const label=decision==='approved'?'Approve Manager Expense Request':'Reject Manager Expense Request';
 L.innerHTML='<div class="bk" data-a="close"></div><form class="md" role="dialog" aria-modal="true" aria-label="'+label+'" id="managerExpenseRequestDecisionForm"><h3>'+label+'</h3><p class="note">This decision applies to the selected branch request. The original expense record remains unchanged if the request is rejected.</p><div class="fl"><label for="managerExpenseRequestReason">Review reason *</label><textarea id="managerExpenseRequestReason" minlength="3" maxlength="500" rows="3" required></textarea></div><div class="tb"><button class="btn pri" id="managerExpenseRequestDecisionSave">Confirm</button><button class="btn" type="button" data-a="close">Cancel</button></div><p id="managerExpenseRequestDecisionError" class="er"></p></form>';
 document.getElementById('managerExpenseRequestDecisionForm').onsubmit=async ev=>{
  ev.preventDefault();const reason=document.getElementById('managerExpenseRequestReason').value.trim(),btn=document.getElementById('managerExpenseRequestDecisionSave'),err=document.getElementById('managerExpenseRequestDecisionError');
  if(reason.length<3){err.textContent='Enter a reason with at least 3 characters.';return}
  btn.disabled=true;btn.textContent='Processing…';
  try{const result=await sb.rpc('edmel_review_manager_expense_request',{p_request_id:id,p_decision:decision,p_reason:reason});if(result.error)throw result.error;if(!result.data?.success)throw new Error('The request decision was not confirmed.');closeL();await loadExpenses();toast(decision==='approved'?'Manager expense request approved.':'Manager expense request rejected.')}
  catch(e){err.textContent=e?.message||'Unable to review this request.';btn.disabled=false;btn.textContent='Confirm'}
 };
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


let expensePolicies=[],emergencyRequests=[],emergencyNotifications=[],expenseAuditRows=[],restaurantTimezone='UTC',profitSummary=null,profitLoading=false,profitError='',profitRequestSequence=0;
const emergencyStatusLabels={pending_authorization:'Pending authorization',authorized:'Authorized',authorized_under_limit:'Within branch limit',rejected:'Rejected',spent_pending_review:'Actuals pending review',reconciled:'Reconciled',reconciliation_rejected:'Correction requested'};
const approvalModeLabels={none:'No approval',manager:'Manager approval',admin:'Owner / Admin approval'};
const expenseBranchPolicy=id=>expensePolicies.find(x=>x.branch_id===id)||{branch_id:id,create_approval_mode:'admin',edit_approval_mode:'admin',void_approval_mode:'admin',emergency_authorization_limit:0};
const requestManagerName=req=>{const u=managerUsers.find(x=>x.id===req.manager_restaurant_user_id);return u?.display_name||u?.full_name||u?.cashier_username||'Manager'};
function expenseTabs(active){
 return '<div class="tb expense-main-tabs" style="flex-wrap:wrap"><button class="btn '+(active==='expenses'?'pri':'')+'" data-a="exptab" data-v="expenses">Expenses</button><button class="btn '+(active==='approvals'?'pri':'')+'" data-a="exptab" data-v="approvals">Approval Center</button><button class="btn '+(active==='profit'?'pri':'')+'" data-a="exptab" data-v="profit">Profit &amp; Loss</button><button class="btn '+(active==='policies'?'pri':'')+'" data-a="exptab" data-v="policies">Approval Policies</button></div>';
}
function approvalCenterPage(){
 const tab=S.f.expApprovalTab||'expense',branch=S.f.expBranch||'';
 const visible=managerRequests.filter(r=>(!branch||r.branch_id===branch)&&r.status==='pending'&&(tab==='expense'?r.request_type==='create':tab==='financial'?['edit','void'].includes(r.request_type):false));
 const history=managerRequests.filter(r=>(!branch||r.branch_id===branch)&&r.status!=='pending');
 const emergency=emergencyRequests.filter(r=>!branch||r.branch_id===branch);
 const pending=visible.length,selected=visible.filter(r=>selectedManagerRequestIds.has(r.id)).length;
 const subTabs=[['expense','Expense Approval'],['emergency','Emergency Authorization'],['financial','Financial Adjustments'],['history','Approval History']];
 const subNav='<div class="tb" style="flex-wrap:wrap">'+subTabs.map(([k,l])=>'<button class="btn '+(tab===k?'pri':'')+'" data-a="expapprovaltab" data-v="'+k+'">'+l+'</button>').join('')+'</div>';
 const branchFilter='<div class="tb"><label class="note">Branch <select data-c="expBranch"><option value="">All accessible branches</option>'+branches.map(b=>'<option value="'+escE(b.id)+'" '+(branch===b.id?'selected':'')+'>'+escE(b.name)+'</option>').join('')+'</select></label><span class="sp"></span><button class="btn" data-a="exprefresh">Refresh</button></div>';
 const reqRows=visible.map(req=>{
  const data=req.request_data||{},row=expenses.find(x=>x.id===req.expense_id);
  const description=req.request_type==='create'?(data.description||'New expense'):req.request_type==='edit'?(data.description||row?.description||'Expense edit'):(row?.description||'Expense void');
  const amount=req.request_type==='void'?row?.amount:data.amount;
  const details=req.request_type==='edit'
   ?'<details style="margin-top:5px"><summary style="cursor:pointer">View before / after</summary><small class="mu" style="display:block">Before: '+escE(row?.description||'—')+' · '+money(row?.amount||0)+' · '+escE(catName(row?.category_id))+'</small><small class="mu" style="display:block">After: '+escE(data.description||'—')+' · '+money(data.amount||0)+' · '+escE(catName(data.category_id))+'</small><small class="mu" style="display:block">Reason: '+escE(data.reason||'—')+'</small><small class="mu" style="display:block">Reference: '+escE(data.reference_number||'—')+'</small><small class="mu" style="display:block">Notes: '+escE(data.notes||'—')+'</small></details>'
   :req.request_type==='void'
    ?'<details style="margin-top:5px"><summary style="cursor:pointer">View void details</summary><small class="mu" style="display:block">Current record: '+escE(row?.description||'—')+' · '+money(row?.amount||0)+'</small><small class="mu" style="display:block">Reason: '+escE(data.reason||'—')+'</small></details>'
    :'<details style="margin-top:5px"><summary style="cursor:pointer">View expense details</summary><small class="mu" style="display:block">Category: '+escE(catName(data.category_id))+' · Date: '+dateText(data.expense_date)+'</small><small class="mu" style="display:block">Payee: '+escE(data.payee||'—')+' · Reference: '+escE(data.reference_number||'—')+'</small><small class="mu" style="display:block">Notes: '+escE(data.notes||'—')+'</small></details>';
  return '<tr><td><input type="checkbox" data-manager-expense-request-select data-id="'+req.id+'" '+(selectedManagerRequestIds.has(req.id)?'checked':'')+' aria-label="Select request"></td><td>'+dateText(req.submitted_at)+'</td><td>'+escE(branchName(req.branch_id))+'</td><td>'+escE(requestManagerName(req))+'</td><td>'+escE(req.request_type)+'</td><td><b>'+escE(description)+'</b>'+details+'</td><td>'+(amount==null?'—':money(amount))+'</td><td>'+statusBadge(req.status)+'</td><td><button class="btn pri" data-a="managerexprequestapprove" data-id="'+req.id+'">Approve</button> <button class="btn" data-a="managerexprequestreject" data-id="'+req.id+'">Reject</button></td></tr>';
 }).join('');
 const reqContent='<section class="card"><div class="row"><div><h3 style="margin:0">'+(tab==='expense'?'Expense Approval': 'Financial Adjustments')+'</h3><p class="note">Requests remain outside the official expense ledger until approved.</p></div><span class="mu">'+pending+' pending</span></div><div class="tb" style="flex-wrap:wrap"><span class="mu">'+selected+' selected</span><button class="btn" data-a="managerexpselectpending" '+(!pending?'disabled':'')+'>Select Pending</button><button class="btn" data-a="managerexpclearselection" '+(!selectedManagerRequestIds.size?'disabled':'')+'>Clear Selection</button><button class="btn pri" data-a="managerexpbulkapprove" '+(!selected?'disabled':'')+'>Approve Selected</button><button class="btn" data-a="managerexpbulkreject" '+(!selected?'disabled':'')+'>Reject Selected</button></div><div class="tw"><table class="inv-table"><thead><tr><th>Select</th><th>Submitted</th><th>Branch</th><th>Manager</th><th>Type</th><th>Description</th><th>Amount</th><th>Status</th><th>Review</th></tr></thead><tbody>'+(reqRows||'<tr><td colspan="9"><div class="empty">No pending requests in this category.</div></td></tr>')+'</tbody></table></div></section>';
 const emergencyRows=emergency.map(r=>{
  const actions=r.status==='pending_authorization'?'<button class="btn pri" data-a="emergencyapprove" data-id="'+r.id+'">Approve</button> <button class="btn" data-a="emergencyreject" data-id="'+r.id+'">Reject</button>':r.status==='spent_pending_review'?'<button class="btn pri" data-a="emergencyreconcile" data-id="'+r.id+'">Reconcile</button> <button class="btn" data-a="emergencyactualreject" data-id="'+r.id+'">Request Correction</button>':'—';
  return '<tr><td>'+dateText(r.created_at)+'</td><td>'+escE(branchName(r.branch_id))+'</td><td>'+escE(requestManagerName({manager_restaurant_user_id:r.manager_restaurant_user_id}))+'</td><td><b>'+escE(r.description)+'</b><small class="mu" style="display:block">'+escE(r.purpose)+'</small></td><td>'+money(r.requested_amount)+'</td><td>'+money(r.authorization_limit)+'</td><td>'+(r.actual_amount==null?'—':money(r.actual_amount))+'</td><td><span class="bd '+(['authorized','authorized_under_limit','reconciled'].includes(r.status)?'ok':r.status==='rejected'?'er':'wn')+'">'+(emergencyStatusLabels[r.status]||escE(r.status))+'</span></td><td>'+actions+'</td></tr>';
 }).join('');
 const emergencyContent='<section class="card"><div class="row"><div><h3 style="margin:0">Emergency Authorization</h3><p class="note">Spending above the branch limit requires Owner/Admin authorization before spending. Actual amount and receipt reference are reviewed after spending.</p></div><span class="mu">'+emergencyRequests.filter(r=>r.status==='pending_authorization'||r.status==='spent_pending_review').length+' awaiting action</span></div>'+(emergencyNotifications.length?'<div class="note" style="padding:10px 0">'+emergencyNotifications.length+' unread emergency notifications</div>':'')+'<div class="tw"><table class="inv-table"><thead><tr><th>Submitted</th><th>Branch</th><th>Manager</th><th>Emergency</th><th>Requested</th><th>Branch Limit</th><th>Actual</th><th>Status</th><th>Action</th></tr></thead><tbody>'+(emergencyRows||'<tr><td colspan="9"><div class="empty">No emergency authorization requests.</div></td></tr>')+'</tbody></table></div></section>';
 const historyRows=history.map(r=>{const data=r.request_data||{},row=expenses.find(x=>x.id===r.expense_id),desc=r.request_type==='create'?(data.description||'New expense'):r.request_type==='edit'?(data.description||row?.description||'Expense edit'):(row?.description||'Expense void');return '<tr><td>'+dateText(r.submitted_at)+'</td><td>'+escE(branchName(r.branch_id))+'</td><td>'+escE(requestManagerName(r))+'</td><td>'+escE(r.request_type)+'</td><td>'+escE(desc)+'</td><td>'+statusBadge(r.status)+'</td><td>'+dateText(r.reviewed_at)+'</td><td>'+escE(r.review_reason||'—')+'</td></tr>'}).join('');
 const emergencyHistory=emergency.filter(r=>!['pending_authorization','spent_pending_review'].includes(r.status)).map(r=>'<tr><td>'+dateText(r.created_at)+'</td><td>'+escE(branchName(r.branch_id))+'</td><td>'+escE(requestManagerName({manager_restaurant_user_id:r.manager_restaurant_user_id}))+'</td><td>Emergency Authorization</td><td>'+escE(r.description)+'</td><td><span class="bd">'+(emergencyStatusLabels[r.status]||r.status)+'</span></td><td>'+dateText(r.final_reviewed_at||r.approved_at)+'</td><td>'+escE(r.final_review_reason||r.decision_reason||'—')+'</td></tr>').join('');
 const auditRows=expenseAuditRows.map(a=>{const before=a.before_data||{},after=a.after_data||{},beforeAmount=before.amount==null?'':money(before.amount),afterAmount=after.amount==null?'':money(after.amount),change=beforeAmount&&afterAmount?beforeAmount+' → '+afterAmount:afterAmount||beforeAmount||'—';return '<tr><td>'+dateText(a.created_at)+'</td><td>'+escE(branchName(a.branch_id))+'</td><td>'+escE(a.actor_name||'System')+'</td><td>'+escE(a.action||'Expense updated')+'</td><td>'+escE(after.description||before.description||'Expense record')+'</td><td>'+escE(change)+'</td><td>'+escE(a.reason||'—')+'</td></tr>'}).join('');
 const historyContent='<section class="card"><h3 style="margin-top:0">Approval History</h3><p class="note">Reviewed Manager requests, emergency decisions, and recorded expense changes. Original decisions and before/after values are preserved.</p><div class="tw"><table class="inv-table"><thead><tr><th>Submitted</th><th>Branch</th><th>Manager</th><th>Type</th><th>Description</th><th>Decision</th><th>Reviewed</th><th>Reason</th></tr></thead><tbody>'+(historyRows+emergencyHistory||'<tr><td colspan="8"><div class="empty">No reviewed requests yet.</div></td></tr>')+'</tbody></table></div><h3>Expense Audit Trail</h3><div class="tw"><table class="inv-table"><thead><tr><th>Date</th><th>Branch</th><th>Actor</th><th>Action</th><th>Record</th><th>Amount</th><th>Reason</th></tr></thead><tbody>'+(auditRows||'<tr><td colspan="7"><div class="empty">No expense audit entries yet.</div></td></tr>')+'</tbody></table></div></section>';
 const notificationBox=managerExpenseNotifications.length||emergencyNotifications.length?'<section class="card"><div class="row"><h3 style="margin:0">Approval Notifications</h3><span class="mu">'+(managerExpenseNotifications.length+emergencyNotifications.length)+' unread</span></div>'+(managerExpenseNotifications.map(n=>'<div class="row"><span>'+escE(n.title)+'<small class="mu" style="display:block">'+escE(n.message)+'</small></span><button class="btn" data-a="managerexpmarkread" data-id="'+n.id+'">Mark read</button></div>').join(''))+(emergencyNotifications.map(n=>'<div class="row"><span>'+escE(n.title)+'<small class="mu" style="display:block">'+escE(n.message)+'</small></span><button class="btn" data-a="emergencymarkread" data-id="'+n.id+'">Mark read</button></div>').join(''))+'</section>':'';
 return subNav+branchFilter+notificationBox+(tab==='expense'||tab==='financial'?reqContent:tab==='emergency'?emergencyContent:historyContent);
}
function emergencyDecisionModal(id,decision){
 const req=emergencyRequests.find(x=>x.id===id);if(!req||req.status!=='pending_authorization')return;
 const label=decision==='approved'?'Authorize Emergency Spending':'Reject Emergency Request';
 L.innerHTML='<div class="bk" data-a="close"></div><form id="emergencyDecisionForm" class="md" role="dialog" aria-modal="true"><h3>'+label+'</h3><p class="note">'+escE(req.description)+' · '+money(req.requested_amount)+' requested · branch limit '+money(req.authorization_limit)+'</p><div class="fl"><label for="emergencyDecisionReason">Decision reason *</label><textarea id="emergencyDecisionReason" minlength="3" maxlength="500" required rows="3"></textarea></div><div class="tb"><button class="btn pri" id="emergencyDecisionSave">Confirm</button><button class="btn" type="button" data-a="close">Cancel</button></div><p id="emergencyDecisionError" class="er"></p></form>';
 document.getElementById('emergencyDecisionForm').onsubmit=async ev=>{ev.preventDefault();const reason=document.getElementById('emergencyDecisionReason').value.trim(),btn=document.getElementById('emergencyDecisionSave'),err=document.getElementById('emergencyDecisionError');if(reason.length<3){err.textContent='Enter a reason with at least 3 characters.';return}btn.disabled=true;btn.textContent='Processing…';try{const {data,error}=await sb.rpc('edmel_review_manager_emergency_authorization',{p_request_id:id,p_decision:decision,p_reason:reason});if(error)throw error;if(!data?.success)throw new Error('The authorization decision was not confirmed.');closeL();await loadExpenses();toast(decision==='approved'?'Emergency spending authorized.':'Emergency request rejected.')}catch(e){err.textContent=e?.message||'Unable to review emergency request.';btn.disabled=false;btn.textContent='Confirm'}};
}
function emergencyActualDecisionModal(id,decision){
 const req=emergencyRequests.find(x=>x.id===id);if(!req||req.status!=='spent_pending_review')return;
 const label=decision==='reconciled'?'Confirm Final Emergency Spend':'Request Correction to Emergency Spend';
 L.innerHTML='<div class="bk" data-a="close"></div><form id="emergencyActualDecisionForm" class="md" role="dialog" aria-modal="true"><h3>'+label+'</h3><p class="note">'+escE(req.description)+' · authorized '+money(req.approved_amount||req.requested_amount)+' · actual '+money(req.actual_amount)+'</p><p class="note">Receipt reference: '+escE(req.actual_receipt_reference||'Not provided')+'</p><div class="fl"><label for="emergencyActualReason">Review reason *</label><textarea id="emergencyActualReason" minlength="3" maxlength="500" required rows="3"></textarea></div><div class="tb"><button class="btn pri" id="emergencyActualSave">Confirm</button><button class="btn" type="button" data-a="close">Cancel</button></div><p id="emergencyActualError" class="er"></p></form>';
 document.getElementById('emergencyActualDecisionForm').onsubmit=async ev=>{ev.preventDefault();const reason=document.getElementById('emergencyActualReason').value.trim(),btn=document.getElementById('emergencyActualSave'),err=document.getElementById('emergencyActualError');if(reason.length<3){err.textContent='Enter a reason with at least 3 characters.';return}btn.disabled=true;btn.textContent='Processing…';try{const {data,error}=await sb.rpc('edmel_review_manager_emergency_actuals',{p_request_id:id,p_decision:decision,p_reason:reason});if(error)throw error;if(!data?.success)throw new Error('The final review was not confirmed.');closeL();await loadExpenses();toast(decision==='reconciled'?'Emergency spending reconciled.':'Correction requested from Manager.')}catch(e){err.textContent=e?.message||'Unable to complete final review.';btn.disabled=false;btn.textContent='Confirm'}};
}
function expensePolicyPage(){
 const selected=S.f.expPolicyBranch||branches.find(b=>b.is_default)?.id||branches[0]?.id||'';
 const p=expenseBranchPolicy(selected);
 return '<section class="card"><div class="row"><div><h3 style="margin:0">Branch Approval Policy</h3><p class="note">Approval mode is configured per branch and per Manager action. Changes apply to new requests only.</p></div><button class="btn" data-a="exprefresh">Refresh</button></div><div class="expense-filters"><label>Branch<select id="expensePolicyBranch" data-c="expPolicyBranch">'+branches.map(b=>'<option value="'+escE(b.id)+'" '+(b.id===selected?'selected':'')+'>'+escE(b.name)+'</option>').join('')+'</select></label><label>Create Expense<select id="policyCreateMode"><option value="none" '+(p.create_approval_mode==='none'?'selected':'')+'>No approval — direct save</option><option value="manager" '+(p.create_approval_mode==='manager'?'selected':'')+'>Manager approval</option><option value="admin" '+(p.create_approval_mode==='admin'?'selected':'')+'>Owner / Admin approval</option></select></label><label>Edit Expense<select id="policyEditMode"><option value="none" '+(p.edit_approval_mode==='none'?'selected':'')+'>No approval — direct save</option><option value="manager" '+(p.edit_approval_mode==='manager'?'selected':'')+'>Manager approval</option><option value="admin" '+(p.edit_approval_mode==='admin'?'selected':'')+'>Owner / Admin approval</option></select></label><label>Void Expense<select id="policyVoidMode"><option value="none" '+(p.void_approval_mode==='none'?'selected':'')+'>No approval — direct void</option><option value="manager" '+(p.void_approval_mode==='manager'?'selected':'')+'>Manager approval</option><option value="admin" '+(p.void_approval_mode==='admin'?'selected':'')+'>Owner / Admin approval</option></select></label><label>Emergency Spending Limit ('+currency+')<input id="policyEmergencyLimit" type="number" min="0" step="0.01" value="'+Number(p.emergency_authorization_limit||0).toFixed(2)+'"></label></div><p class="note">Emergency requests above this amount require Owner/Admin authorization before spending. Requests at or below the limit are recorded as authorized under branch policy and still require actual-spend reconciliation. Managers with Manage permission can directly create and edit expenses; the configured void approval mode still applies.</p><div class="tb"><button class="btn pri" data-a="exppolicysave" data-branch="'+escE(selected)+'">Save Branch Policy</button></div></section>';
}
async function saveExpensePolicy(t){
 const branchId=t.dataset.branch||S.f.expPolicyBranch;if(!branchId){toast('Select a branch first.',1);return}
 const limit=Number(document.getElementById('policyEmergencyLimit')?.value);
 if(!Number.isFinite(limit)||limit<0){toast('Enter a valid emergency spending limit.',1);return}
 const row={restaurant_id:CURRENT_RESTAURANT_ID,branch_id:branchId,
  create_approval_mode:document.getElementById('policyCreateMode').value,
  edit_approval_mode:document.getElementById('policyEditMode').value,
  void_approval_mode:document.getElementById('policyVoidMode').value,
  emergency_authorization_limit:limit,updated_at:new Date().toISOString()};
 const {data:userData,error:userError}=await sb.auth.getUser();if(userError||!userData?.user){toast('Admin session unavailable.',1);return}
 row.updated_by_user_id=userData.user.id;
 const {error}=await sb.from('restaurant_expense_policies').upsert(row,{onConflict:'restaurant_id,branch_id'});
 if(error){toast('Could not save branch policy: '+error.message,1);return}
 try{await sb.from('audit_logs').insert({restaurant_id:CURRENT_RESTAURANT_ID,actor_user_id:userData.user.id,actor_name:userData.user.email||'Admin',actor_role:'admin',action_category:'Expenses & Profit',action:'Updated branch expense approval policy',record_type:'restaurant_expense_policy',record_id:branchId,result:'success',details:{create_approval_mode:row.create_approval_mode,edit_approval_mode:row.edit_approval_mode,void_approval_mode:row.void_approval_mode,emergency_authorization_limit:limit}})}catch(_){}
 await loadExpenses();toast('Branch expense approval policy saved.');
}
function addIsoDays(iso,days){const d=new Date(iso+'T00:00:00Z');d.setUTCDate(d.getUTCDate()+days);return d.toISOString().slice(0,10)}
function dateInRestaurantZone(date){const p=new Intl.DateTimeFormat('en-CA',{timeZone:restaurantTimezone||'UTC',year:'numeric',month:'2-digit',day:'2-digit'}).formatToParts(date);const v={};p.forEach(x=>{if(x.type!=='literal')v[x.type]=x.value});return v.year+'-'+v.month+'-'+v.day}
function profitRangeDates(){
 const today=dateInRestaurantZone(new Date()),monthStart=today.slice(0,7)+'-01',yearStart=today.slice(0,4)+'-01-01';
 let start=today,end=addIsoDays(today,1);
 switch(S.per){
  case'yest':start=addIsoDays(today,-1);end=today;break;
  case'7d':start=addIsoDays(today,-6);break;
  case'30d':start=addIsoDays(today,-29);break;
  case'tm':start=monthStart;break;
  case'lm':{const d=new Date(monthStart+'T00:00:00Z');d.setUTCMonth(d.getUTCMonth()-1);start=d.toISOString().slice(0,10);end=monthStart;break}
  case'ty':start=yearStart;break;
  case'cu':start=S.cu0;end=addIsoDays(S.cu1,1);break;
  default:break;
 }
 return {start,end};
}
async function loadProfitSummary(){
 const seq=++profitRequestSequence,{start,end}=profitRangeDates();
 if(!start||!end||end<=start){profitSummary=null;profitError='Choose a valid custom date range.';profitLoading=false;if(S.page==='exp'&&S.f.expTab==='profit')render();return}
 profitLoading=true;profitError='';if(S.page==='exp'&&S.f.expTab==='profit')render();
 try{
  const {data,error}=await sb.rpc('edmel_get_expense_profit_summary',{p_restaurant_id:CURRENT_RESTAURANT_ID,p_branch_id:S.f.expBranch||null,p_start_date:start,p_end_date_exclusive:end});
  if(error)throw error;if(seq!==profitRequestSequence)return;
  profitSummary=data||null;
 }catch(e){if(seq===profitRequestSequence){profitSummary=null;profitError=e?.message||'Unable to load Profit & Loss summary.'}}
 finally{if(seq===profitRequestSequence){profitLoading=false;if(S.page==='exp'&&S.f.expTab==='profit')render()}}
}
function profitPage(){
 const branch=S.f.expBranch||'',period=Object.entries(PER).map(([k,v])=>'<option value="'+k+'" '+(S.per===k?'selected':'')+'>'+v[0]+'</option>').join('');
 if(profitLoading)return '<div class="tb"><label class="note">Period <select data-c="per">'+period+'</select></label><label class="note">Branch <select data-c="expBranch"><option value="">All accessible branches</option>'+branches.map(b=>'<option value="'+escE(b.id)+'" '+(branch===b.id?'selected':'')+'>'+escE(b.name)+'</option>').join('')+'</select></label></div><section class="card"><div class="empty">Loading timezone-aware sales and expense totals…</div></section>';
 if(profitError)return '<div class="tb"><label class="note">Period <select data-c="per">'+period+'</select></label><label class="note">Branch <select data-c="expBranch"><option value="">All accessible branches</option>'+branches.map(b=>'<option value="'+escE(b.id)+'" '+(branch===b.id?'selected':'')+'>'+escE(b.name)+'</option>').join('')+'</select></label><span class="sp"></span><button class="btn" data-a="profitrefresh">Retry</button></div><section class="card"><span class="bd er">Report unavailable</span><p>'+escE(profitError)+'</p></section>';
 const p=profitSummary||{},start=p.period_start||'',end=p.period_end_exclusive?addIsoDays(p.period_end_exclusive,-1):'';
 const custom=S.per==='cu'?'<label class="note">From <input type="date" data-c="cu0" value="'+escE(S.cu0)+'"></label><label class="note">To <input type="date" data-c="cu1" value="'+escE(S.cu1)+'"></label>':'';
 return '<div class="tb"><label class="note">Period <select data-c="per">'+period+'</select></label>'+custom+'<label class="note">Branch <select data-c="expBranch"><option value="">All accessible branches</option>'+branches.map(b=>'<option value="'+escE(b.id)+'" '+(branch===b.id?'selected':'')+'>'+escE(b.name)+'</option>').join('')+'</select></label><span class="sp"></span><button class="btn" data-a="profitrefresh">Refresh</button></div><p class="note">Reporting timezone: '+escE(p.timezone||restaurantTimezone)+' · '+escE(start)+' to '+escE(end)+'</p><div class="g k"><div class="card"><div class="mu">Settled Net Sales</div><div class="big">'+money(p.net_sales||0)+'</div><small class="mu">'+Number(p.sales_order_count||0)+' paid and settled orders</small></div><div class="card"><div class="mu">Discounts</div><div class="big">'+money(p.discounts||0)+'</div><small class="mu">From settled orders</small></div><div class="card"><div class="mu">Approved Expenses</div><div class="big">'+money(p.approved_expenses||0)+'</div><small class="mu">'+Number(p.approved_expense_count||0)+' approved records</small></div><div class="card"><div class="mu">Pre-COGS Operating Balance</div><div class="big">'+money(p.pre_cogs_operating_balance||0)+'</div><small class="mu">Net sales less approved expenses only</small></div></div><section class="card"><div class="row"><h3 style="margin:0">Profit Readiness</h3><span class="bd wn">Net Profit not available yet</span></div><p>True gross profit and net profit cannot be calculated yet because EDMEL has no connected recipe / ingredient cost-of-goods-sold (COGS) records or refund / chargeback ledger for this restaurant.</p><div class="g g2"><div><div class="mu">Tax collected (not sales income)</div><div class="big">'+money(p.tax_collected||0)+'</div></div><div><div class="mu">Total collected (includes tax, tips and service charges)</div><div class="big">'+money(p.total_collected||0)+'</div></div></div><div class="g g2"><div><div class="mu">Tips collected</div><div class="big">'+money(p.tips_collected||0)+'</div></div><div><div class="mu">Service charges collected</div><div class="big">'+money(p.service_charges_collected||0)+'</div></div></div><p class="note">The Pre-COGS Operating Balance is not Net Profit. It excludes ingredient cost, inventory consumption, refunds / chargebacks and other accounting adjustments. We will not display a fabricated profit percentage.</p></section>';
}
function enhancedExpensePage(){
 const active=S.f.expTab||'expenses';
 if(active==='approvals')return '<div class="expense-p2">'+expenseTabs(active)+approvalCenterPage()+'</div>';
 if(active==='profit')return '<div class="expense-p2">'+expenseTabs(active)+profitPage()+'</div>';
 if(active==='policies')return '<div class="expense-p2">'+expenseTabs(active)+expensePolicyPage()+'</div>';
 return '<div class="expense-p2">'+expenseTabs('expenses')+expensePage()+'</div>';
}

PG.exp=enhancedExpensePage;
A.exptab=t=>{S.f.expTab=t.dataset.v;render();if(S.f.expTab==='profit')loadProfitSummary();else if(S.f.expTab==='approvals'||S.f.expTab==='policies')loadExpenses()};
A.expapprovaltab=t=>{S.f.expApprovalTab=t.dataset.v;selectedManagerRequestIds.clear();render()};
A.emergencyapprove=t=>emergencyDecisionModal(t.dataset.id,'approved');
A.emergencyreject=t=>emergencyDecisionModal(t.dataset.id,'rejected');
A.emergencyreconcile=t=>emergencyActualDecisionModal(t.dataset.id,'reconciled');
A.emergencyactualreject=t=>emergencyActualDecisionModal(t.dataset.id,'rejected');
A.emergencymarkread=async t=>{try{const {error}=await sb.from('manager_emergency_authorization_notifications').update({is_read:true,read_at:new Date().toISOString()}).eq('id',t.dataset.id).eq('restaurant_id',CURRENT_RESTAURANT_ID).eq('recipient_role','admin');if(error)throw error;await loadExpenses();toast('Emergency notification marked as read.')}catch(e){toast(e?.message||'Unable to update emergency notification.',1)}};
A.exppolicysave=t=>saveExpensePolicy(t);
A.profitrefresh=()=>loadProfitSummary();
async function showExpenseNotificationDrawer(){
 try{
  const [n,e]=await Promise.all([
   sb.from('manager_expense_request_notifications').select('id,title,message,created_at').eq('restaurant_id',CURRENT_RESTAURANT_ID).eq('recipient_role','admin').eq('is_read',false).order('created_at',{ascending:false}).limit(30),
   sb.from('manager_emergency_authorization_notifications').select('id,title,message,created_at').eq('restaurant_id',CURRENT_RESTAURANT_ID).eq('recipient_role','admin').eq('is_read',false).order('created_at',{ascending:false}).limit(30)
  ]);
  if(n.error)throw n.error;if(e.error)throw e.error;
  const all=[...(n.data||[]).map(x=>({...x,kind:'expense'})),...(e.data||[]).map(x=>({...x,kind:'emergency'}))].sort((a,b)=>new Date(b.created_at)-new Date(a.created_at));
  L.innerHTML='<div class="bk" data-a="close" style="background:none"></div><div class="pn" role="dialog" aria-label="Notifications"><div class="row"><b>Notifications</b><span class="mu">'+all.length+' unread approval alerts</span><button class="btn" data-a="expnotifreadall" '+(!all.length?'disabled':'')+'>Mark all read</button></div>'+(all.map(x=>'<div class="row" style="align-items:flex-start;gap:10px;padding:10px 0;border-top:1px solid var(--bd)"><div style="flex:1;min-width:0"><b>'+escE(x.title)+'</b><div class="mu">'+escE(x.message)+'</div><small class="mu">'+dateText(x.created_at)+'</small></div><button class="btn" data-a="'+(x.kind==='emergency'?'emergencymarkread':'managerexpmarkread')+'" data-id="'+x.id+'">Mark read</button></div>').join('')||empty('You’re all caught up.') )+'<button class="btn pri" style="margin-top:10px" data-a="go" data-p="exp">Open Expenses &amp; Profit</button></div>';
 }catch(e){toast('Could not load approval notifications: '+(e?.message||String(e)),1)}
}
A.bell=()=>showExpenseNotificationDrawer();
const oldManagerExpenseMarkRead=A.managerexpmarkread;
A.managerexpmarkread=async t=>{if(oldManagerExpenseMarkRead)await oldManagerExpenseMarkRead(t);await showExpenseNotificationDrawer()};
const oldEmergencyMarkRead=A.emergencymarkread;
A.emergencymarkread=async t=>{if(oldEmergencyMarkRead)await oldEmergencyMarkRead(t);await showExpenseNotificationDrawer()};

A.expnotifreadall=async()=>{try{const now=new Date().toISOString();const [a,b]=await Promise.all([sb.from('manager_expense_request_notifications').update({is_read:true,read_at:now}).eq('restaurant_id',CURRENT_RESTAURANT_ID).eq('recipient_role','admin').eq('is_read',false),sb.from('manager_emergency_authorization_notifications').update({is_read:true,read_at:now}).eq('restaurant_id',CURRENT_RESTAURANT_ID).eq('recipient_role','admin').eq('is_read',false)]);if(a.error)throw a.error;if(b.error)throw b.error;closeL();toast('Approval notifications marked as read.')}catch(e){toast(e?.message||'Unable to mark notifications as read.',1)}};

A.addexp=()=>expenseForm(null);
A.expcats=()=>categoryModal();
A.expcattoggle=t=>toggleCategory(t.dataset.id);
A.exprefresh=()=>loadExpenses();
A.expedit=t=>{const x=expenses.find(e=>e.id===t.dataset.id);if(x)expenseForm(x);else toast('Expense record not found.',1)};
A.expdetail=t=>expenseDetail(t.dataset.id);
A.expapprove=t=>decisionModal(t.dataset.id,'approved');
A.expreject=t=>decisionModal(t.dataset.id,'rejected');
A.expvoid=t=>decisionModal(t.dataset.id,'voided');
A.managerexprequestapprove=t=>managerExpenseRequestDecisionModal(t.dataset.id,'approved');
A.managerexprequestreject=t=>managerExpenseRequestDecisionModal(t.dataset.id,'rejected');
A.managerexpselectpending=()=>{if(!S.f.expBranch){toast('Select one branch first.',1);return}const category=S.f.expApprovalTab||'expense';const pending=managerRequests.filter(r=>r.branch_id===S.f.expBranch&&r.status==='pending'&&(category==='financial'?['edit','void'].includes(r.request_type):category==='expense'?r.request_type==='create':true));selectedManagerRequestIds=new Set(pending.slice(0,50).map(r=>r.id));if(pending.length>50)toast('Selected the first 50 pending requests in this category. Review the remaining requests separately.',1);render()};
A.managerexpclearselection=()=>{selectedManagerRequestIds.clear();render()};
A.managerexpbulkapprove=()=>managerExpenseBulkDecisionModal('approved');
A.managerexpbulkreject=()=>managerExpenseBulkDecisionModal('rejected');
A.managerexpmarkread=async t=>{try{const {error}=await sb.from('manager_expense_request_notifications').update({is_read:true,read_at:new Date().toISOString()}).eq('id',t.dataset.id).eq('restaurant_id',CURRENT_RESTAURANT_ID).eq('recipient_role','admin');if(error)throw error;await loadExpenses();toast('Notification marked as read.')}catch(e){toast(e?.message||'Unable to update notification.',1)}};
const oldGo=A.go;
A.go=t=>{const page=t?.dataset?.p;oldGo(t);if(page==='exp')loadExpenses()};
document.addEventListener('change',ev=>{
 const t=ev.target;
 if(t?.dataset?.c==='expBranch'||t?.dataset?.c==='expCategory'||t?.dataset?.c==='expStatus'||t?.dataset?.c==='per'||t?.dataset?.c==='cu0'||t?.dataset?.c==='cu1'){
  if(t.dataset.c==='per')S.per=t.value;else if(t.dataset.c==='cu0'||t.dataset.c==='cu1')S[t.dataset.c]=t.value;else S.f[t.dataset.c]=t.value;
  if(t.dataset.c==='expBranch')selectedManagerRequestIds.clear();
  render();if(S.f.expTab==='profit')loadProfitSummary();return;
 }
 if(t?.id==='expensePolicyBranch'){S.f.expPolicyBranch=t.value;render();return;}
});
document.addEventListener('change',ev=>{const t=ev.target;if(!t?.matches('[data-manager-expense-request-select]'))return;if(t.checked)selectedManagerRequestIds.add(t.dataset.id);else selectedManagerRequestIds.delete(t.dataset.id);render()});
document.addEventListener('input',ev=>{
 const t=ev.target;if(t?.dataset?.c!=='expQ')return;
 S.f.expQ=t.value;const pos=t.selectionStart;render();const next=document.querySelector('#pg [data-c="expQ"]');if(next){next.focus();next.setSelectionRange(pos,pos)}
});
const css=document.createElement('style');css.id='edmel-expense-phase2-css';css.textContent=`
.expense-main-tabs{border-bottom:1px solid var(--bd);padding-bottom:10px}.expense-main-tabs .btn{min-width:130px}

.expense-p2{display:grid;gap:14px}.expense-filters{display:grid;grid-template-columns:repeat(4,minmax(130px,1fr));gap:12px}
.expense-filters label{display:grid;gap:5px;color:var(--mu);font-size:12px;font-weight:600}
.expense-filters input,.expense-filters select{width:100%;min-width:0}
@media(max-width:760px){.expense-filters{grid-template-columns:repeat(2,minmax(0,1fr))}}
@media(max-width:480px){.expense-filters{grid-template-columns:1fr}}
`;document.head.appendChild(css);
const previousDashboardLoad=load;
load=async function(manual){const result=await previousDashboardLoad(manual);if(S.page==='exp')await loadExpenses();return result};
if(S.page==='exp')loadExpenses();
})();
