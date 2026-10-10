import { useCallback, useEffect, useMemo, useState } from 'react'
import { dataService } from './services/data'
import type { Role } from './models'
import { ManifestScanPanel, MachineIssueForm, ProductionOutputForm, ScanLookup, StockAdjustmentRequestForm } from './LiveActions'

type Row = Record<string, unknown>
type Config = { title: string; description: string; table: string; select: string; order?: string; filter?: [string, string]; labels: string[] }

const base: Record<string, Config> = {
  '/orders': { title: 'Buyer orders', description: 'Order status and commitments read from the live operations ledger.', table: 'buyer_orders', select: 'id,order_number,status,priority,promised_date,currency,created_at', order: 'created_at', labels: ['order_number','status','priority','promised_date','currency'] },
  '/plans': { title: 'Production plans', description: 'Planned quantity, release state and dates from live plans.', table: 'production_plans', select: 'id,plan_no,status,planned_qty,planned_start,planned_end,estimated_completion,is_demo', order: 'created_at', labels: ['plan_no','status','planned_qty','planned_start','estimated_completion','is_demo'] },
  '/operations': { title: 'Production operations', description: 'Assignments and operation state from the live shop-floor board.', table: 'production_operations', select: 'id,operation_no,stage,sequence,status,machine_id,shift_id,target_qty,unit,at_risk,planned_start,is_demo', order: 'created_at', labels: ['operation_no','stage','sequence','status','target_qty','unit','at_risk'] },
  '/shift-board': { title: 'Shift board', description: 'Current operation status and recorded work; no synthetic KPIs.', table: 'production_operations', select: 'id,operation_no,stage,status,target_qty,unit,planned_start,actual_start,at_risk,is_demo', order: 'created_at', labels: ['operation_no','stage','status','target_qty','unit','planned_start','at_risk'] },
  '/my-jobs': { title: 'My jobs', description: 'Assigned operation records returned under the signed-in operator’s row-level policy.', table: 'production_operations', select: 'id,operation_no,stage,status,machine_id,shift_id,target_qty,unit,planned_start,at_risk', order: 'created_at', labels: ['operation_no','stage','status','target_qty','unit','planned_start'] },
  '/stores': { title: 'Stock by location', description: 'Balances are derived from posted movements and active reservations.', table: 'v_yarn_stock', select: 'yarn_item_id,yarn_batch_id,location_id,on_hand,reserved,quarantined,available,expected', labels: ['yarn_item_id','yarn_batch_id','location_id','on_hand','reserved','quarantined','available','expected'] },
  '/inventory/shortages': { title: 'Inventory shortages', description: 'Live stock rows show available, reserved, quarantined and expected balances.', table: 'v_yarn_stock', select: 'yarn_item_id,yarn_batch_id,location_id,on_hand,reserved,quarantined,available,expected', labels: ['yarn_item_id','yarn_batch_id','location_id','available','reserved','quarantined','expected'] },
  '/stores/ledger': { title: 'Movement ledger', description: 'Append-only inventory movements from the live ledger.', table: 'inventory_movements', select: 'id,movement_no,item_kind,movement_type,qty,unit,source_type,created_at,is_demo', order: 'created_at', labels: ['movement_no','item_kind','movement_type','qty','unit','source_type','created_at','is_demo'] },
  '/stores/reservations': { title: 'Material reservations', description: 'Current plan reservations and consumption state.', table: 'material_reservations', select: 'id,plan_id,yarn_batch_id,qty,consumed_qty,status,reserved_by,created_at,is_demo', order: 'created_at', labels: ['plan_id','yarn_batch_id','qty','consumed_qty','status','created_at','is_demo'] },
  '/stores/quarantine': { title: 'Quarantined material', description: 'Quarantined inventory stays separate from available stock.', table: 'yarn_batches', select: 'id,batch_code,supplier_lot,received_qty,accepted_qty,damaged_qty,quarantined_qty,unit,status,hold_reason,is_demo', filter: ['status','eq.QUARANTINED'], order: 'created_at', labels: ['batch_code','supplier_lot','received_qty','accepted_qty','quarantined_qty','unit','status','hold_reason'] },
  '/stores/receipts': { title: 'Yarn receipts', description: 'Post a split receipt through the permission-checked receipt RPC; quarantined and damaged quantities do not become available.', table: 'purchase_receipts', select: 'id,receipt_number,delivery_reference,status,received_at,is_demo', order: 'created_at', labels: ['receipt_number','delivery_reference','status','received_at','is_demo'] },
  '/quality/queue': { title: 'Inspection queue', description: 'Only awaiting-inspection rolls are offered for QC decisions. A decision is persisted by the quality RPC.', table: 'fabric_rolls', select: 'id,roll_code,qty,unit,status,current_stage,location_id,hold_reason,is_demo', filter: ['status','in.(AWAITING_INSPECTION,REINSPECTION_REQUIRED)'], order: 'created_at', labels: ['roll_code','qty','unit','status','current_stage','location_id','hold_reason'] },
  '/quality/holds': { title: 'Quality holds', description: 'Hold status and location are loaded from the roll records.', table: 'fabric_rolls', select: 'id,roll_code,qty,unit,status,current_stage,location_id,hold_reason,is_demo', filter: ['status','in.(QUARANTINED,REWORK_REQUIRED,REJECTED)'], order: 'created_at', labels: ['roll_code','qty','unit','status','current_stage','location_id','hold_reason'] },
  '/quality/rework': { title: 'Rework queue', description: 'Open rework work orders, with mandatory reinspection after completion.', table: 'rework_orders', select: 'id,rework_no,roll_id,status,notes,created_at,is_demo', order: 'created_at', labels: ['rework_no','roll_id','status','notes','created_at','is_demo'] },
  '/dispatch/ready': { title: 'Dispatch-ready rolls', description: 'Only quality-accepted rolls are eligible. Backend revalidates order scope, location, holds and remaining quantity.', table: 'fabric_rolls', select: 'id,roll_code,order_line_id,qty,unit,status,location_id,hold_reason,is_demo', filter: ['status','eq.ACCEPTED'], order: 'created_at', labels: ['roll_code','order_line_id','qty','unit','status','location_id'] },
  '/dispatch/rolls': { title: 'Eligible rolls', description: 'Live accepted finished rolls; quarantined, rejected and uninspected rolls are excluded.', table: 'fabric_rolls', select: 'id,roll_code,order_line_id,qty,unit,status,location_id,hold_reason,is_demo', filter: ['status','eq.ACCEPTED'], order: 'created_at', labels: ['roll_code','order_line_id','qty','unit','status','location_id'] },
  '/dispatch/drafts': { title: 'Shipment drafts', description: 'Shipment state from the dispatch ledger; confirm remains a separate review step.', table: 'shipments', select: 'id,shipment_number,order_id,status,requested_qty,manifest_expected_count,manifest_scanned_count,needs_attention,carrier,vehicle_no,is_demo', order: 'created_at', labels: ['shipment_number','order_id','status','requested_qty','manifest_expected_count','manifest_scanned_count','needs_attention','carrier'] },
  '/dispatch/history': { title: 'Dispatch history', description: 'Confirmed shipment records from the live dispatch ledger.', table: 'shipments', select: 'id,shipment_number,order_id,status,requested_qty,manifest_expected_count,manifest_scanned_count,dispatched_at,tracking_reference,is_demo', order: 'created_at', labels: ['shipment_number','order_id','status','requested_qty','manifest_scanned_count','dispatched_at','tracking_reference'] },
  '/machines': { title: 'Machine board', description: 'Machine status, type and location are read from master data and status events.', table: 'machines', select: 'id,machine_code,name,machine_type,status,location,capacity_per_hour,capacity_unit,is_active,source', order: 'machine_code', labels: ['machine_code','name','machine_type','status','location','capacity_per_hour','capacity_unit','source'] },
  '/maintenance': { title: 'Maintenance work orders', description: 'Maintenance status and spares readiness from the maintenance ledger.', table: 'maintenance_work_orders', select: 'id,wo_number,machine_id,type,status,due_at,window_start,window_end,spares_ready,created_at', order: 'created_at', labels: ['wo_number','machine_id','type','status','due_at','spares_ready'] },
  '/handover': { title: 'Shift handover', description: 'Submitted handover records and acknowledgement state.', table: 'shift_handovers', select: 'id,handover_no,shift_instance_id,status,notes,acknowledged_at,is_demo', order: 'created_at', labels: ['handover_no','shift_instance_id','status','notes','acknowledged_at','is_demo'] },
  '/tasks': { title: 'Tasks', description: 'Work items created by real workflow events and assigned to roles.', table: 'tasks', select: 'id,task_no,title,assignee_role,status,due_at,entity_type,entity_id,is_demo', order: 'created_at', labels: ['task_no','title','assignee_role','status','due_at','entity_type'] },
  '/exceptions': { title: 'Exception inbox', description: 'Dedupe-aware exceptions and next-step ownership.', table: 'exceptions', select: 'id,exception_no,type,severity,status,title,owner_role,due_at,occurrence_count,is_demo', order: 'opened_at', labels: ['exception_no','type','severity','status','title','owner_role','due_at','occurrence_count'] },
  '/approvals': { title: 'Approval inbox', description: 'Approval requests with requester, permission and decision state.', table: 'approval_requests', select: 'id,request_type,entity_type,entity_id,requested_by,required_permission,status,deadline,reason', order: 'created_at', labels: ['request_type','entity_type','entity_id','required_permission','status','deadline'] },
  '/admin/users': { title: 'Users & approvals', description: 'Identity status and role assignment are governed by audited admin RPCs.', table: 'profiles', select: 'id,email,full_name,status,requested_role,last_login_at,mfa_required,created_at', order: 'created_at', labels: ['email','full_name','status','requested_role','last_login_at','mfa_required'] },
  '/admin/roles': { title: 'Roles & permissions', description: 'Database-seeded role definitions and authorization catalogue.', table: 'roles', select: 'id,key,name,description,is_system', order: 'key', labels: ['key','name','description','is_system'] },
  '/admin/automations': { title: 'Automation console', description: 'Rule inventory from Postgres. Provider execution remains disabled or safely draft-only until configured.', table: 'automation_rules', select: 'id,code,name,mode,enabled,owner_role,last_run_at,last_result,next_run_at,failure_reason,retry_count,config', order: 'code', labels: ['code','name','mode','enabled','owner_role','last_run_at','last_result','next_run_at','failure_reason'] },
  '/admin/integrations': { title: 'Integration health', description: 'Honest state from provider records; unconfigured channels are not marked delivered.', table: 'integration_events', select: 'id,provider,event_key,status,attempts,last_error,is_simulated,created_at', order: 'created_at', labels: ['provider','status','attempts','last_error','is_simulated','created_at'] },
  '/admin/audit': { title: 'Audit log', description: 'Read-only audit rows with secrets excluded.', table: 'audit_logs', select: 'id,actor_user_id,action,entity_type,entity_id,reason,created_at', order: 'created_at', labels: ['action','entity_type','entity_id','reason','created_at'] },
  '/hr/attendance': { title: 'Attendance', description: 'Example attendance records are synthetic and pending review; not payroll outcomes.', table: 'attendance_records', select: 'id,employee_id,shift_id,work_date,status,check_in,check_out,overtime_minutes,approval_status,is_demo', order: 'work_date', labels: ['employee_id','work_date','shift_id','status','overtime_minutes','approval_status','is_demo'] },
  '/hr/roster': { title: 'Shift roster', description: 'Roster assignments by employee, shift and work date.', table: 'shift_roster', select: 'id,employee_id,shift_id,work_date,is_demo', order: 'work_date', labels: ['employee_id','shift_id','work_date','is_demo'] },
  '/hr/skills': { title: 'Skills & certification', description: 'Skills, worker certifications and expiry dates.', table: 'employee_skills', select: 'employee_id,skill_id,certified_until,is_demo', order: 'certified_until', labels: ['employee_id','skill_id','certified_until','is_demo'] },
  '/hr/payroll': { title: 'Payroll periods', description: 'Example rules only — not statutory. Draft payroll requires a verified HR workflow.', table: 'payroll_periods', select: 'id,period_no,period_start,period_end,status,calculated_by,approved_by,needs_recalc', order: 'period_start', labels: ['period_no','period_start','period_end','status','needs_recalc'] },
  '/finance/orders': { title: 'Order costs', description: 'Source-linked costs only. Amounts are private to finance and are not shown to buyers.', table: 'cost_entries', select: 'id,order_id,category_id,description,amount,currency,cost_basis,source_type,source_id,created_at', order: 'created_at', labels: ['order_id','category_id','description','amount','currency','cost_basis','source_type','source_id'] },
  '/finance/entries': { title: 'Cost entries', description: 'Recorded costs with basis and source fields.', table: 'cost_entries', select: 'id,order_id,category_id,description,amount,currency,cost_basis,source_type,source_id,created_at', order: 'created_at', labels: ['order_id','category_id','description','amount','currency','cost_basis','source_type','source_id'] },
  '/finance/invoices': { title: 'Invoice drafts', description: 'Internal invoice references only; no payment or statutory tax action is performed.', table: 'invoices', select: 'id,invoice_number,shipment_id,order_id,invoice_date,due_date,currency,subtotal,tax_rate,tax_amount,total,status', order: 'created_at', labels: ['invoice_number','shipment_id','order_id','invoice_date','currency','subtotal','tax_amount','total','status'] },
  '/finance/expenses': { title: 'Expenses', description: 'Submitted and approved expenses; unapproved rows are not treated as actual cost.', table: 'expenses', select: 'id,expense_no,category_id,order_id,amount,currency,status,approved_by,created_at', order: 'created_at', labels: ['expense_no','category_id','order_id','amount','currency','status','created_at'] },
  '/portal': { title: 'My orders', description: 'Buyer-safe, buyer-scoped order milestones; internal notes, rates and cost are never queried.', table: 'rpc_buyer_list_orders', select: '', labels: ['order_number','status','promised_date','created_at'] },
  '/dispatch-board': { title: 'Production dispatch board', description: 'Live operation lanes include due window, machine, assignment and risk reason; suggestions remain recommendations.', table: 'production_operations', select: 'id,operation_no,plan_id,stage,sequence,status,machine_id,shift_id,target_qty,unit,waiting_reason,at_risk,planned_start,planned_end,is_demo', order: 'planned_start', labels: ['operation_no','stage','sequence','status','machine_id','shift_id','target_qty','unit','waiting_reason','at_risk','planned_start'] },
  '/record-output': { title: 'Record output', description: 'Review recorded good, waste and reject quantities; new output is posted through an idempotent server RPC.', table: 'production_outputs', select: 'id,operation_id,shift_instance_id,work_date,good_qty,waste_qty,reject_qty,unit,waste_reason,reject_reason,status,recorded_at,is_demo', order: 'recorded_at', labels: ['operation_id','work_date','good_qty','waste_qty','reject_qty','unit','waste_reason','reject_reason','status','recorded_at'] },
  '/wip': { title: 'Work in progress', description: 'Roll-level WIP, inspection and rework states remain separate from accepted finished goods.', table: 'fabric_rolls', select: 'id,roll_code,order_line_id,plan_id,qty,unit,status,current_stage,location_id,hold_reason,is_demo', filter: ['status','in.(IN_PRODUCTION,AWAITING_INSPECTION,REINSPECTION_REQUIRED,REWORK_REQUIRED,REWORK_IN_PROGRESS)'], order: 'created_at', labels: ['roll_code','order_line_id','qty','unit','status','current_stage','location_id','hold_reason'] },
  '/stores/counts': { title: 'Cycle counts', description: 'Open and submitted physical counts show system and observed quantities; variance is not posted until separately approved.', table: 'cycle_counts', select: 'id,location_id,status,counted_by,created_at,submitted_at,is_demo', order: 'created_at', labels: ['location_id','status','counted_by','created_at','submitted_at','is_demo'] },
  '/stores/adjustments': { title: 'Stock adjustments', description: 'Adjustment requests are separate from the append-only ledger and require the server-side approval path.', table: 'stock_adjustments', select: 'id,adj_no,yarn_batch_id,roll_id,location_id,qty_delta,reason,status,requested_by,approved_by,created_at,is_demo', order: 'created_at', labels: ['adj_no','yarn_batch_id','roll_id','location_id','qty_delta','reason','status','requested_by','approved_by','created_at'] },
  '/stores/rfq': { title: 'RFQ drafts', description: 'Draft requisitions show their quantity and source; nothing is sent to a supplier from this prototype.', table: 'purchase_orders', select: 'id,po_number,supplier_id,status,expected_date,currency,is_rfq_draft,price_flag,created_at,is_demo', filter: ['is_rfq_draft','eq.true'], order: 'created_at', labels: ['po_number','supplier_id','status','expected_date','currency','is_rfq_draft','price_flag'] },
  '/quality/incidents': { title: 'Quality incidents', description: 'Investigation status is explicit; thresholds are prompts for review, not confirmed root causes.', table: 'quality_incidents', select: 'id,incident_no,trigger,status,root_cause,details,opened_by,closed_at,is_demo,created_at', order: 'created_at', labels: ['incident_no','trigger','status','root_cause','details','opened_by','created_at'] },
  '/quality/defects': { title: 'Defect analytics', description: 'Recorded defect positions are shown as demo evidence, not AI release decisions.', table: 'quality_defects', select: 'id,inspection_id,defect_category_id,severity,quantity_or_extent,unit,pos_x,pos_y,notes,is_demo,created_at', order: 'created_at', labels: ['inspection_id','defect_category_id','severity','quantity_or_extent','unit','pos_x','pos_y','notes','created_at'] },
  '/quality/plans': { title: 'Inspection plans', description: 'Versioned checklists and sampling rules are read-only in this preview; changes require the quality-plan permission.', table: 'inspection_plans', select: 'id,product_id,process_id,name,version,sampling_rule,is_active,source', order: 'version', labels: ['product_id','process_id','name','version','sampling_rule','is_active','source'] },
  '/dispatch/scan': { title: 'Manifest scan events', description: 'Scan outcomes are sourced from the dispatch ledger; mismatches are never silently accepted.', table: 'shipment_scan_events', select: 'id,shipment_id,roll_code,result,scanned_by,scanned_at,is_demo', order: 'scanned_at', labels: ['shipment_id','roll_code','result','scanned_by','scanned_at','is_demo'] },
  '/dispatch/documents': { title: 'Dispatch documents', description: 'Only document metadata is shown; pending files are not presented as downloadable or buyer-approved.', table: 'documents', select: 'id,doc_type,entity_type,entity_id,version,status,attempts,buyer_shareable,generated_at,is_demo', order: 'created_at', labels: ['doc_type','entity_type','entity_id','version','status','attempts','buyer_shareable','generated_at'] },
  '/hr/corrections': { title: 'Attendance corrections', description: 'Pending attendance corrections remain visible for review; this page does not silently alter source attendance.', table: 'attendance_records', select: 'id,employee_id,shift_id,work_date,status,check_in,check_out,overtime_minutes,approval_status,approved_by,is_demo', filter: ['approval_status','eq.PENDING'], order: 'work_date', labels: ['employee_id','work_date','status','check_in','check_out','overtime_minutes','approval_status'] },
  '/hr/reports': { title: 'Attendance & workforce report', description: 'Source attendance and shift roster records are role-scoped; these are demo records, not payroll outcomes.', table: 'attendance_records', select: 'id,employee_id,shift_id,work_date,status,overtime_minutes,approval_status,is_demo', order: 'work_date', labels: ['employee_id','shift_id','work_date','status','overtime_minutes','approval_status'] },
  '/finance/variance': { title: 'Cost variance cases', description: 'Planned-to-recorded variance cases show their formula and review state; contribution is not audited profit.', table: 'cost_variance_cases', select: 'id,order_id,category_id,variance_amount,variance_pct,status,breakdown,reviewed_by,is_demo,created_at', order: 'created_at', labels: ['order_id','category_id','variance_amount','variance_pct','status','breakdown','reviewed_by','created_at'] },
  '/finance/exports': { title: 'Cost export', description: 'Export only the finance rows already visible under RLS, including currency, basis and source columns.', table: 'cost_entries', select: 'id,order_id,category_id,description,amount,currency,cost_basis,source_type,source_id,created_at', order: 'created_at', labels: ['order_id','category_id','description','amount','currency','cost_basis','source_type','source_id'] },
  '/admin/settings': { title: 'System settings', description: 'Setting names and descriptions are shown without exposing stored values or credentials.', table: 'system_settings', select: 'key,description,updated_by,updated_at', order: 'key', labels: ['key','description','updated_by','updated_at'] },
  '/admin/reconciliation': { title: 'Inventory reconciliation', description: 'Read-only ledger balances by batch and location; discrepancies require the audited adjustment workflow.', table: 'v_yarn_stock', select: 'yarn_item_id,yarn_batch_id,location_id,on_hand,reserved,quarantined,available,expected', labels: ['yarn_item_id','yarn_batch_id','location_id','on_hand','reserved','quarantined','available','expected'] },
  '/notifications': { title: 'Notification centre', description: 'Only in-app notices belonging to the signed-in user are queried; provider email is not configured.', table: 'notifications', select: 'id,type,severity,title,body,entity_type,entity_id,action_url,read_at,is_demo,created_at', order: 'created_at', labels: ['type','severity','title','body','entity_type','action_url','read_at','created_at'] },
  '/quality/scan': { title: 'Scan roll', description: 'Manual or camera lookup is read-only until a specific inspection decision is submitted.', table: 'fabric_rolls', select: 'id,roll_code,qr_token,qty,unit,status,current_stage,location_id,hold_reason,is_demo', order: 'created_at', labels: ['roll_code','qty','unit','status','current_stage','location_id','hold_reason'] },
  '/scan-machine': { title: 'Scan machine', description: 'Resolve a machine or QR identifier before taking an authorised shop-floor action.', table: 'machines', select: 'id,machine_code,name,status,location,capacity_per_hour,capacity_unit,is_active', order: 'machine_code', labels: ['machine_code','name','status','location','capacity_per_hour','capacity_unit'] },
  '/report-issue': { title: 'Report a machine issue', description: 'The allowed breakdown transition records linked downtime and an actionable exception.', table: 'machines', select: 'id,machine_code,name,status,location,is_active', order: 'machine_code', labels: ['machine_code','name','status','location','is_active'] },
  '/portal/documents': { title: 'Buyer documents', description: 'Only buyer-shareable metadata is queried; file links require a separate signed-download service.', table: 'documents', select: 'id,doc_type,entity_type,entity_id,version,status,attempts,buyer_shareable,generated_at,is_demo', filter: ['buyer_shareable','eq.true'], order: 'created_at', labels: ['doc_type','entity_type','entity_id','version','status','buyer_shareable','generated_at'] },
  '/portal/changes': { title: 'Change requests', description: 'Buyer-scoped request status and requested change only; impact approval remains internal.', table: 'order_change_requests', select: 'id,order_id,request_type,payload,status,created_at,is_demo', order: 'created_at', labels: ['order_id','request_type','payload','status','created_at'] },
  '/reports': { title: 'Operations report — order load', description: 'Role-scoped order states and commitments. Export is limited to the rows returned by this report query.', table: 'buyer_orders', select: 'id,order_number,status,priority,promised_date,currency,created_at', order: 'created_at', labels: ['order_number','status','priority','promised_date','currency','created_at'] },
}

const titleFallback: Record<string, string> = {
  '/stores/counts': 'Cycle counts', '/stores/adjustments': 'Stock adjustments', '/stores/rfq': 'RFQ drafts', '/quality/incidents': 'Quality incidents', '/quality/defects': 'Defect analytics', '/quality/plans': 'Inspection plans', '/dispatch/scan': 'Manifest scan', '/dispatch/documents': 'Dispatch documents', '/hr/corrections': 'Attendance corrections', '/hr/reports': 'HR reports', '/finance/variance': 'Cost variance', '/finance/exports': 'Financial exports', '/portal/timeline': 'Order timeline', '/portal/documents': 'Buyer documents', '/portal/changes': 'Change requests',
}
function display(value: unknown) {
  if (value === null || value === undefined || value === '') return '—'
  if (typeof value === 'boolean') return value ? 'Yes' : 'No'
  if (typeof value === 'object') return JSON.stringify(value)
  return String(value)
}
function safeError(error: unknown) {
  const message = error instanceof Error ? error.message : ''
  const code = message.match(/CODE:\s*([A-Z0-9_]+)/)?.[1]
  const messages: Record<string,string> = { INSUFFICIENT_STOCK: 'Not enough available stock. Review the shortage and available balance.', ROLL_NOT_ELIGIBLE: 'This roll is not quality-accepted and cannot be dispatched.', PERMISSION_DENIED: 'Your account does not have permission for this action.', INVALID_STATE_TRANSITION: 'That state change is not permitted from the current record state.', RECEIPT_QTY_MISMATCH: 'Received quantity must equal accepted + damaged + quarantined.', SHIPMENT_NOT_ALLOCATED: 'Allocate eligible rolls before confirming this shipment.', MANIFEST_MISMATCH_ACK_REQUIRED: 'Scan every allocated roll or record a reasoned mismatch acknowledgement.' }
  return code ? messages[code] ?? `The action was blocked (${code}). Review the record and try the permitted next step.` : 'The request could not be completed. Check your access and record state, then retry.'
}

export default function LivePage({ path, role, onNavigate }: { path: string; role: Role; onNavigate: (path: string) => void }) {
  const client = dataService.getClient()
  const config = base[path]
  const [rows,setRows]=useState<Row[]>([])
  const [loading,setLoading]=useState(true)
  const [error,setError]=useState('')
  const [notice,setNotice]=useState('')
  const [refresh,setRefresh]=useState(0)
  const [suppliers,setSuppliers]=useState<Row[]>([])
  const [items,setItems]=useState<Row[]>([])
  const [supplierId,setSupplierId]=useState('')
  const [itemId,setItemId]=useState('')
  const [receiptValues,setReceiptValues]=useState({delivery:'',received:'500',accepted:'430',damaged:'40',quarantined:'30',unitCost:'120'})
  const [selected,setSelected]=useState<string[]>([])
  const [orderOptions,setOrderOptions]=useState<Row[]>([])
  const [buyerOptions,setBuyerOptions]=useState<Row[]>([])
  const [productOptions,setProductOptions]=useState<Row[]>([])
  const [orderDraft,setOrderDraft]=useState({buyer:'',product:'',quantity:'2000',rate:'185',colour:'Indigo',due:new Date(Date.now()+21*86400000).toISOString().slice(0,10)})
  const [workflowOrderId,setWorkflowOrderId]=useState('')
  const [workflowLineId,setWorkflowLineId]=useState('')
  const [workflowPlanId,setWorkflowPlanId]=useState('')
  const [feasibility,setFeasibility]=useState<Row|null>(null)
  const [orderId,setOrderId]=useState('')
  const [working,setWorking]=useState(false)
  const [summary,setSummary]=useState<Record<string,number> | null>(null)

  const load=useCallback(async()=>{
    if(!client){setLoading(false);setError('Supabase frontend variables are not configured.');return}
    setLoading(true);setError('');
    try {
      if(path==='/portal'||path==='/portal/timeline'){
        const {data,error}=await client.rpc('rpc_buyer_list_orders')
        if(error)throw error
        const buyerOrders=Array.isArray(data)?data as Row[]:[]
        if(path==='/portal/timeline'&&buyerOrders.length){
          const first=buyerOrders[0]
          const id=first.order_id??first.id
          if(id){const timeline=await client.rpc('rpc_buyer_order_timeline',{p_order_id:id});if(timeline.error)throw timeline.error;setRows(timeline.data&&typeof timeline.data==='object'?[timeline.data as Row]:[])}else setRows(buyerOrders)
        }else setRows(buyerOrders)
      } else if(config){
        let q=client.from(config.table).select(config.select).limit(50)
        if(config.filter){const [col,filter]=config.filter;if(filter.startsWith('in.'))q=q.in(col,filter.slice(3, -1).split(','));else q=q.eq(col,filter.slice(3))}
        if(config.order)q=q.order(config.order,{ascending:false,nullsFirst:false})
        const {data,error}=await q
        if(error)throw error
        setRows((data??[]) as unknown as Row[])
      } else if(path==='/command-centre') {
        const {data,error}=await client.from('production_operations').select('id,operation_no,stage,status,target_qty,unit,at_risk,planned_start').limit(12)
        if(error)throw error
        setRows((data??[]) as unknown as Row[])
      } else setRows([])
      if(path==='/stores/receipts'){
        const [s,i]=await Promise.all([client.from('suppliers').select('id,supplier_code,name').eq('is_active',true).limit(50),client.from('yarn_items').select('id,item_code,name,unit,standard_unit_cost,preferred_supplier_id').eq('is_active',true).limit(50)])
        if(s.error)throw s.error;if(i.error)throw i.error
        setSuppliers((s.data??[]) as Row[]);setItems((i.data??[]) as Row[])
        if(!supplierId && s.data?.[0])setSupplierId(String(s.data[0].id))
        if(!itemId && i.data?.[0]){setItemId(String(i.data[0].id));setReceiptValues(v=>({...v,unitCost:String(i.data[0].standard_unit_cost??120)}))}
      }
      if(path==='/orders'){
        const [b,p]=await Promise.all([client.from('buyers').select('id,buyer_code,name,currency').eq('is_active',true).limit(50),client.from('products').select('id,product_code,description,colour,unit,standard_roll_length').eq('is_active',true).limit(50)])
        if(b.error)throw b.error;if(p.error)throw p.error
        setBuyerOptions((b.data??[]) as unknown as Row[]);setProductOptions((p.data??[]) as unknown as Row[])
        if(!orderDraft.buyer&&b.data?.[0])setOrderDraft(v=>({...v,buyer:String(b.data[0].id)}))
        if(!orderDraft.product&&p.data?.[0])setOrderDraft(v=>({...v,product:String(p.data[0].id),colour:String(p.data[0].colour??'')}))
      }
      if(['/dispatch/ready','/dispatch/rolls','/dispatch/drafts','/dispatch/scan'].includes(path)){
        const o=await client.from('buyer_orders').select('id,order_number,status,promised_date').limit(50)
        if(o.error)throw o.error
        setOrderOptions((o.data??[]) as unknown as Row[])
        if(o.data?.length && !orderId)setOrderId(String(o.data[0].id))
      }
      if(path==='/command-centre'){
        const specs=[['orders',()=>client.from('buyer_orders').select('id',{count:'exact',head:true}).in('status',['CONFIRMED','PLANNED','IN_PRODUCTION','PARTIALLY_DISPATCHED'])],['inspection',()=>client.from('fabric_rolls').select('id',{count:'exact',head:true}).eq('status','AWAITING_INSPECTION')],['accepted',()=>client.from('fabric_rolls').select('id',{count:'exact',head:true}).eq('status','ACCEPTED')],['exceptions',()=>client.from('exceptions').select('id',{count:'exact',head:true}).in('status',['OPEN','ACKNOWLEDGED','IN_PROGRESS'])]] as const
        const res=await Promise.all(specs.map(async([k,fn])=>{const r=await fn();return{k,count:r.count,error:r.error} as const}))
        const failed=res.find(r=>r.error)
        if(failed?.error)throw failed.error
        setSummary(Object.fromEntries(res.map(r=>[r.k,r.count??0])))
      }
    } catch(e){setError(safeError(e))} finally{setLoading(false)}
  },[client,path,config,refresh,supplierId,itemId,orderId,orderDraft.buyer,orderDraft.product])
  useEffect(()=>{void load()},[load])

  const act=async(name:string,args:Record<string,unknown>)=>{
    if(!client)throw new Error('not configured')
    const {data,error}=await client.rpc(name,args as never)
    if(error)throw error
    return data as Row
  }
  const run=async(label:string,fn:()=>Promise<unknown>)=>{
    setWorking(true);setError('');setNotice('')
    try{const out=await fn();setNotice(label);setRefresh(x=>x+1);return out}
    catch(e){setError(safeError(e));return null}finally{setWorking(false)}
  }
  const title=config?.title??titleFallback[path]??(path.split('/').filter(Boolean).at(-1)?.replaceAll('-',' ')??'Workspace')
  const description=config?.description??'Live records are permission-scoped by Supabase; actions are enforced in Postgres.'
  const orderRows=useMemo(()=>rows,[rows])

  async function postReceipt(event:React.FormEvent){
    event.preventDefault();const total=Number(receiptValues.received),accepted=Number(receiptValues.accepted),damaged=Number(receiptValues.damaged),quarantined=Number(receiptValues.quarantined)
    await run('Receipt posted successfully.',async()=>{const result=await act('rpc_post_receipt',{p_supplier_id:supplierId,p_po_id:null,p_delivery_reference:receiptValues.delivery||'MANUAL-RECEIPT',p_lines:[{yarn_item_id:itemId,received_qty:total,accepted_qty:accepted,damaged_qty:damaged,quarantined_qty:quarantined,unit:String(items.find(i=>String(i.id)===itemId)?.unit??'kg'),unit_cost:Number(receiptValues.unitCost),supplier_lot:receiptValues.delivery||`UI-${crypto.randomUUID().slice(0,8)}`}],p_idempotency_key:crypto.randomUUID()});setNotice(`Receipt ${String(result.receipt_number??'')} posted.`);return result})
  }
  async function decideRoll(row:Row,result:'PASS'|'REWORK'|'QUARANTINE'){
    const defects=result==='PASS'?[]:[{category_code:result==='REWORK'?'HOLE':'CONTAM',severity:result==='REWORK'?'MAJOR':'CRITICAL',quantity_or_extent:1,unit:'defect',notes:result==='REWORK'?'Rework requested from QC screen.':'Quarantine requested from QC screen.'}]
    await run(`Inspection recorded: ${result}.`,()=>act('rpc_inspect_roll',{p_roll_id:row.id,p_result:result,p_notes:`Decision submitted from quality queue (${result}).`,p_measurements:[],p_defects:defects,p_idempotency_key:crypto.randomUUID()}))
  }
  async function createShipment(){
    const rolls=rows.filter(r=>selected.includes(String(r.id)))
    if(!orderId||!rolls.length){setError('Select an order and at least one accepted roll.');return}
    const quantity=rolls.reduce((n,r)=>n+Number(r.qty??0),0)
    const created=await run('Shipment draft allocated. Continue to the manual manifest scan.',async()=>{
      const created=await act('rpc_create_shipment',{p_order_id:orderId,p_requested_qty:quantity,p_idempotency_key:crypto.randomUUID(),p_carrier:'',p_vehicle_no:''})
      const sid=String(created.shipment_id)
      await act('rpc_allocate_rolls',{p_shipment_id:sid,p_roll_ids:rolls.map(r=>r.id),p_idempotency_key:crypto.randomUUID()})
      return created
    })
    if(created)onNavigate('/dispatch/scan')
  }
  async function createOrder(event:React.FormEvent){
    event.preventDefault()
    const product=productOptions.find(p=>String(p.id)===orderDraft.product)
    const buyer=buyerOptions.find(b=>String(b.id)===orderDraft.buyer)
    if(!product||!buyer){setError('Select an active buyer and product.');return}
    const created=await run('Order created. Run feasibility before confirming.',()=>act('rpc_create_order',{p_payload:{buyer_id:orderDraft.buyer,requested_date:new Date().toISOString().slice(0,10),promised_date:orderDraft.due,priority:'NORMAL',currency:String(buyer.currency??'INR'),notes_buyer:'',notes_internal:'',lines:[{product_id:orderDraft.product,colour:orderDraft.colour||product.colour,ordered_qty:Number(orderDraft.quantity),unit:String(product.unit??'m'),unit_rate:Number(orderDraft.rate)}]},p_idempotency_key:crypto.randomUUID()}))
    if(created){const result=created as Row;const lines=Array.isArray(result.lines)?result.lines as Row[]:[];setWorkflowOrderId(String(result.order_id??''));setWorkflowLineId(String(lines[0]?.id??''));setWorkflowPlanId('');setFeasibility(null);setNotice(`Order ${String(result.order_number??'')} created.`)}
  }
  async function runFeasibility(){
    if(!workflowOrderId){setError('Create an order before running feasibility.');return}
    await run('Feasibility snapshot stored.',async()=>{const result=await act('rpc_run_feasibility',{p_order_id:workflowOrderId});setFeasibility(result);return result})
  }
  async function confirmWorkflowOrder(){
    if(!workflowOrderId)return
    await run('Order confirmed.',()=>act('rpc_confirm_order',{p_order_id:workflowOrderId,p_idempotency_key:crypto.randomUUID(),p_override_reason:null}))
  }
  async function createWorkflowPlan(){
    if(!workflowLineId){setError('The created order line was not returned; create the order again or use its supported planning flow.');return}
    const result=await run('Production plan created. Release it to reserve material.',()=>act('rpc_create_plan',{p_order_line_id:workflowLineId,p_planned_qty:Number(orderDraft.quantity),p_idempotency_key:crypto.randomUUID()}))
    if(result&&typeof result==='object')setWorkflowPlanId(String((result as Row).plan_id??''))
  }
  async function releaseWorkflowPlan(){
    if(!workflowPlanId)return
    await run('Plan released and reservation processed atomically.',()=>act('rpc_release_plan',{p_plan_id:workflowPlanId,p_idempotency_key:crypto.randomUUID()}))
  }

  if(path==='/command-centre')return <>
    <div className="hero-row"><div><p className="eyebrow">Factory control room</p><h1>Command centre</h1><p className="lead">Live counts from role-scoped Supabase queries. Select a card to open its source list.</p></div><div className="hero-actions"><button className="button button-secondary" onClick={()=>setRefresh(x=>x+1)}>Refresh</button></div></div>
    <div className="live-stat-grid">{[['Active orders',summary?.orders,'/orders'],['Awaiting inspection',summary?.inspection,'/quality/queue'],['Accepted rolls',summary?.accepted,'/dispatch/ready'],['Open exceptions',summary?.exceptions,'/exceptions']].map(([label,value,to])=><button className="live-stat" key={String(label)} onClick={()=>onNavigate(String(to))}><span>{label}</span><strong>{loading?'…':value??'—'}</strong><small>Live query · open records →</small></button>)}</div>
    {error&&<div className="live-error">{error}</div>}{notice&&<div className="live-success">{notice}</div>}
    <DataTable title="Active operations" rows={rows} labels={[]} loading={loading} error={error} onRefresh={()=>setRefresh(x=>x+1)} />
    <div className="live-note">Operational simulation is explicitly tagged DEMO DATA; provider messaging is NOT CONFIGURED. Counts are live database aggregates.</div>
  </>

  return <>
    <div className="hero-row"><div><p className="eyebrow">{role.replaceAll('_',' ')}</p><h1>{title}</h1><p className="lead">{description}</p></div><div className="hero-actions"><button className="button button-secondary" onClick={()=>setRefresh(x=>x+1)}>Refresh data</button>{path==='/stores/receipts'&&<span className="status-chip status-demo-data">Demo-safe RPC</span>}</div></div>
    {path==='/hr/payroll'&&<div className="live-warning">Example rules — not statutory. Confirm policy before real use.</div>}
    {error&&<div className="live-error" role="alert">{error}</div>}{notice&&<div className="live-success" role="status">{notice}</div>}
    {path==='/record-output'&&<ProductionOutputForm onSaved={()=>setRefresh(x=>x+1)} />}
    {path==='/scan-machine'&&<ScanLookup kind="machine" />}
    {path==='/quality/scan'&&<ScanLookup kind="roll" />}
    {path==='/dispatch/scan'&&<ManifestScanPanel onSaved={()=>setRefresh(x=>x+1)} />}
    {path==='/report-issue'&&<MachineIssueForm onSaved={()=>setRefresh(x=>x+1)} />}
    {path==='/stores/adjustments'&&<StockAdjustmentRequestForm onSaved={()=>setRefresh(x=>x+1)} />}
    {path==='/orders'&&role==='factory_manager'&&<section className="live-panel"><h2>Create order and plan</h2><p>The server calculates BOM, stock, route and risk. An order cannot be confirmed while blocked unless the separately approved override path is used.</p><form className="live-form" onSubmit={createOrder}>
      <label>Buyer<select value={orderDraft.buyer} onChange={e=>setOrderDraft(v=>({...v,buyer:e.target.value}))} required>{buyerOptions.map(b=><option key={String(b.id)} value={String(b.id)}>{String(b.buyer_code)} · {String(b.name)}</option>)}</select></label>
      <label>Product<select value={orderDraft.product} onChange={e=>{const p=productOptions.find(x=>String(x.id)===e.target.value);setOrderDraft(v=>({...v,product:e.target.value,colour:String(p?.colour??'')}))}} required>{productOptions.map(p=><option key={String(p.id)} value={String(p.id)}>{String(p.product_code)} · {String(p.description)}</option>)}</select></label>
      <label>Quantity<input type="number" min="1" step="1" value={orderDraft.quantity} onChange={e=>setOrderDraft(v=>({...v,quantity:e.target.value}))} required /></label>
      <label>Unit rate (INR)<input type="number" min="0" step="0.01" value={orderDraft.rate} onChange={e=>setOrderDraft(v=>({...v,rate:e.target.value}))} required /></label>
      <label>Colour<input value={orderDraft.colour} onChange={e=>setOrderDraft(v=>({...v,colour:e.target.value}))} required /></label>
      <label>Promised date<input type="date" value={orderDraft.due} onChange={e=>setOrderDraft(v=>({...v,due:e.target.value}))} required /></label>
      <div className="live-form-actions"><span>Customer commitment is a date estimate until reviewed and confirmed.</span><button className="button button-primary" disabled={working||!buyerOptions.length||!productOptions.length}>{working?'Saving…':'Create order'}</button></div>
    </form>{workflowOrderId&&<div className="live-actions"><button className="button button-secondary" disabled={working} onClick={()=>void runFeasibility()}>Run feasibility</button><button className="button button-secondary" disabled={working||!feasibility||String(feasibility.result)==='BLOCKED'} onClick={()=>void confirmWorkflowOrder()}>Confirm order</button><button className="button button-secondary" disabled={working||!workflowLineId||!feasibility||String(feasibility.result)==='BLOCKED'} onClick={()=>void createWorkflowPlan()}>Create plan</button><button className="button button-primary" disabled={working||!workflowPlanId} onClick={()=>void releaseWorkflowPlan()}>Release plan · reserve material</button></div>}{workflowOrderId&&<p className="live-note">Order {workflowOrderId} · plan {workflowPlanId||'not created yet'} · {feasibility?`feasibility ${String(feasibility.result??'stored')}`:'run feasibility to continue'}{feasibility&&<pre className="live-json">{JSON.stringify(feasibility.details??feasibility,null,2)}</pre>}</p>}</section>}
    {path==='/stores/receipts'&&<section className="live-panel"><h2>Post a yarn receipt</h2><p>Accepted + damaged + quarantined must equal received. Only accepted quantity is placed in RAW stock.</p><form className="live-form" onSubmit={postReceipt}>
      <label>Supplier<select value={supplierId} onChange={e=>setSupplierId(e.target.value)} required>{suppliers.map(s=><option key={String(s.id)} value={String(s.id)}>{String(s.supplier_code)} · {String(s.name)}</option>)}</select></label>
      <label>Yarn item<select value={itemId} onChange={e=>setItemId(e.target.value)} required>{items.map(i=><option key={String(i.id)} value={String(i.id)}>{String(i.item_code)} · {String(i.name)}</option>)}</select></label>
      <label>Delivery reference<input value={receiptValues.delivery} onChange={e=>setReceiptValues(v=>({...v,delivery:e.target.value}))} placeholder="Packing slip / delivery note" /></label>
      <label>Received qty<input type="number" min="0.001" step="0.001" value={receiptValues.received} onChange={e=>setReceiptValues(v=>({...v,received:e.target.value}))} required /></label>
      <label>Accepted<input type="number" min="0" step="0.001" value={receiptValues.accepted} onChange={e=>setReceiptValues(v=>({...v,accepted:e.target.value}))} required /></label>
      <label>Damaged<input type="number" min="0" step="0.001" value={receiptValues.damaged} onChange={e=>setReceiptValues(v=>({...v,damaged:e.target.value}))} required /></label>
      <label>Quarantined<input type="number" min="0" step="0.001" value={receiptValues.quarantined} onChange={e=>setReceiptValues(v=>({...v,quarantined:e.target.value}))} required /></label>
      <label>Unit cost<input type="number" min="0" step="0.01" value={receiptValues.unitCost} onChange={e=>setReceiptValues(v=>({...v,unitCost:e.target.value}))} required /></label>
      <div className="live-form-actions"><span>Balance: {Number(receiptValues.accepted)+Number(receiptValues.damaged)+Number(receiptValues.quarantined)} / {receiptValues.received} kg</span><button className="button button-primary" disabled={working||!supplierId||!itemId||Number(receiptValues.accepted)+Number(receiptValues.damaged)+Number(receiptValues.quarantined)!==Number(receiptValues.received)}>{working?'Posting…':'Post receipt'}</button></div>
    </form></section>}
    {path==='/quality/queue'&&<div className="live-note">Choose a decision per roll. REWORK and QUARANTINE create controlled quality records; no decision is inferred by the browser.</div>}
    {path==='/dispatch/ready'&&<section className="live-panel"><h2>Review shipment allocation</h2><p>Choose one order and accepted rolls. The server rechecks order scope, state, location and remaining quantity.</p><label className="live-inline">Order<select value={orderId} onChange={e=>setOrderId(e.target.value)} required><option value="">Select an order</option>{orderOptions.map(o=><option key={String(o.id)} value={String(o.id)}>{String(o.order_number)} · {String(o.status)}</option>)}</select></label><div className="live-actions"><button className="button button-primary" disabled={!selected.length||!orderId||working} onClick={()=>void createShipment()}>Create draft + allocate {selected.length} rolls</button><button className="button button-secondary" onClick={()=>onNavigate('/dispatch/scan')}>Open manifest scan</button></div><p className="live-note">Dispatch is not confirmed here. Continue to the one-roll-at-a-time manifest scan and review before confirmation.</p></section>}
    {path==='/dispatch/rolls'&&<div className="live-note">Eligible list is filtered to ACCEPTED status by the database query. Dispatch is committed through the allocation and confirmation RPCs.</div>}
    {path==='/finance/orders'&&<div className="live-warning">Amounts are restricted to finance roles. Contribution is not audited profit; invoice rows remain drafts until separately approved.</div>}
    {path!=='/record-output'&&path!=='/scan-machine'&&path!=='/quality/scan'&&path!=='/dispatch/scan'&&path!=='/report-issue'&&path!=='/stores/adjustments'&&<DataTable title={path==='/dispatch/ready'?'Eligible rolls':path==='/quality/queue'?'Live records':title} rows={orderRows} labels={config?.labels??[]} loading={loading} error={error} onRefresh={()=>setRefresh(x=>x+1)} selectable={path==='/dispatch/ready'} selected={selected} onSelect={setSelected} qualityActions={path==='/quality/queue'?decideRoll:undefined} busy={working} />}
  </>
}

function DataTable({title,rows,labels,loading,error,onRefresh,selectable=false,selected=[],onSelect,qualityActions,busy=false}:{title:string;rows:Row[];labels:string[];loading:boolean;error:string;onRefresh:()=>void;selectable?:boolean;selected?:string[];onSelect?:(ids:string[])=>void;qualityActions?:(row:Row,result:'PASS'|'REWORK'|'QUARANTINE')=>void;busy?:boolean}){
 const cols=labels.length?labels:(rows[0]?Object.keys(rows[0]).filter(k=>!['id','is_demo','created_at'].includes(k)).slice(0,7):[])
 return <section className="live-panel"><div className="live-panel-head"><div><h2>{title}</h2><p>{loading?'Loading live rows…':`${rows.length} row${rows.length===1?'':'s'} shown (maximum 50)`}</p></div><button className="button button-quiet" onClick={onRefresh}>Refresh</button></div>
  {error?<p className="live-empty">Rows could not be shown under the current role or query.</p>:loading?<p className="live-empty">Loading from Supabase…</p>:rows.length===0?<p className="live-empty">No rows returned by the live query.</p>:<div className="live-table-wrap"><table className="live-table"><thead><tr>{selectable&&<th>Select</th>}{cols.map(c=><th key={c}>{c.replaceAll('_',' ')}</th>)}{qualityActions&&<th>Decision</th>}</tr></thead><tbody>{rows.map((row,index)=><tr key={String(row.id??index)}>{selectable&&<td><input aria-label="Select eligible roll" type="checkbox" checked={selected.includes(String(row.id))} onChange={e=>onSelect?.(e.target.checked?[...selected,String(row.id)]:selected.filter(id=>id!==String(row.id)))}/></td>}{cols.map(c=><td key={c}>{display(row[c])}</td>)}{qualityActions&&<td className="live-row-actions"><button className="button button-quiet" disabled={busy} onClick={()=>qualityActions(row,'PASS')}>Pass</button><button className="button button-quiet" disabled={busy} onClick={()=>qualityActions(row,'REWORK')}>Rework</button><button className="button button-quiet" disabled={busy} onClick={()=>qualityActions(row,'QUARANTINE')}>Quarantine</button></td>}</tr>)}</tbody></table></div>}
  <div className="live-table-foot">Role-scoped · Supabase RLS · values from live rows · {selectable?'demo tags preserved':''}</div>
 </section>
}
