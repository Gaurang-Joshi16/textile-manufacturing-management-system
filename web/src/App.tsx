import { useEffect, useMemo, useState, type ReactNode } from 'react'
import {
  AlertCircle,
  AlertTriangle,
  Archive,
  ArrowRight,
  Bell,
  Check,
  CheckCircle2,
  ChevronDown,
  ChevronRight,
  CircleDashed,
  Clock3,
  Command,
  Database,
  Download,
  FileSearch,
  Filter,
  Grid2X2,
  Info,
  Keyboard,
  LayoutList,
  Menu,
  MinusCircle,
  PackageCheck,
  PanelLeftClose,
  PanelLeftOpen,
  QrCode,
  Radio,
  RefreshCcw,
  RotateCcw,
  ScanLine,
  Search,
  Send,
  ShieldAlert,
  SlidersHorizontal,
  Sparkles,
  Wrench,
  X,
} from 'lucide-react'
import type { LucideIcon } from 'lucide-react'
import './App.css'
import { dataService } from './services/data'
import { useAuth } from './Auth'
import { navByRole, roleMeta } from './navigation'
import LivePage from './LivePages'
import type { EmptyViewModel, NavItem, QueryCard, Role, StatusKind, TimelineEvent } from './models'

const roleOptions = Object.keys(roleMeta) as Role[]
const floorRoles: Role[] = ['production_supervisor', 'machine_operator', 'storekeeper', 'quality_inspector', 'dispatch_officer']
const routePermissions: Record<string, string> = {
  '/admin/users': 'users.manage', '/admin/roles': 'roles.manage', '/admin/settings': 'settings.manage', '/admin/automations': 'automations.manage', '/admin/integrations': 'integrations.manage', '/admin/audit': 'audit.read', '/admin/reconciliation': 'settings.manage',
  '/command-centre': 'dashboard.manager', '/exceptions': 'orders.read', '/approvals': 'approvals.decide', '/orders': 'orders.read', '/plans': 'plans.create', '/dispatch-board': 'production.assign', '/machines': 'machines.read', '/inventory/shortages': 'inventory.read',
  '/quality/holds': 'quality.read', '/quality/queue': 'quality.read', '/quality/rework': 'quality.read', '/quality/incidents': 'quality.incident', '/quality/defects': 'quality.read', '/quality/plans': 'quality.plans_manage', '/quality/scan': 'quality.inspect',
  '/dispatch/ready': 'dispatch.read', '/dispatch/rolls': 'dispatch.read', '/dispatch/drafts': 'dispatch.create', '/dispatch/scan': 'dispatch.create', '/dispatch/history': 'dispatch.read', '/dispatch/documents': 'dispatch.read',
  '/stores/receipts': 'inventory.receive', '/stores': 'inventory.read', '/stores/ledger': 'inventory.read', '/stores/reservations': 'inventory.reserve', '/stores/quarantine': 'inventory.quarantine', '/stores/adjustments': 'inventory.adjust_request', '/stores/counts': 'inventory.count', '/stores/rfq': 'purchasing.draft',
  '/shift-board': 'production.read', '/operations': 'production.read', '/maintenance': 'maintenance.manage', '/handover': 'production.handover', '/wip': 'inventory.read', '/tasks': 'tasks.manage', '/my-jobs': 'production.read', '/scan-machine': 'machines.read', '/record-output': 'production.record_output', '/report-issue': 'machines.status',
  '/hr/roster': 'hr.read', '/hr/attendance': 'hr.read', '/hr/corrections': 'attendance.approve', '/hr/payroll': 'payroll.read', '/hr/skills': 'hr.read', '/hr/reports': 'reports.read',
  '/finance/orders': 'finance.read', '/finance/variance': 'finance.read', '/finance/entries': 'finance.cost_entry', '/finance/expenses': 'expenses.approve', '/finance/invoices': 'finance.approve', '/finance/exports': 'reports.financial_export', '/reports': 'reports.read', '/portal': 'buyer.portal', '/portal/timeline': 'buyer.portal', '/portal/documents': 'buyer.portal', '/portal/changes': 'buyer.portal', '/notifications': 'buyer.portal',
}

const statusIcon: Record<StatusKind, LucideIcon> = {
  'Waiting for material': CircleDashed,
  'QC hold': ShieldAlert,
  'Awaiting inspection': Clock3,
  'Rework required': RotateCcw,
  Accepted: CheckCircle2,
  'Reserved for shipment': Archive,
  Dispatched: Send,
  Breakdown: AlertTriangle,
  'Planned maintenance': Wrench,
  Simulated: Radio,
  'Demo data': Database,
  Estimated: Clock3,
  Allocated: PackageCheck,
  Actual: Check,
  Ready: CheckCircle2,
  'No records yet': MinusCircle,
  'Not configured': Info,
}

function getRouteFromHash(fallback: string) {
  const route = window.location.hash.replace(/^#/, '')
  return route || fallback
}

function StatusChip({ status, compact = false }: { status: StatusKind; compact?: boolean }) {
  const Icon = statusIcon[status]
  return (
    <span className={`status-chip status-${status.toLowerCase().replaceAll(' ', '-')}${compact ? ' status-compact' : ''}`}>
      <Icon size={compact ? 13 : 14} strokeWidth={2} aria-hidden="true" />
      <span>{status}</span>
    </span>
  )
}

function Button({
  children,
  variant = 'secondary',
  onClick,
  icon: Icon,
  className = '',
  disabled = false,
  type = 'button',
}: {
  children: ReactNode
  variant?: 'primary' | 'secondary' | 'quiet' | 'danger'
  onClick?: () => void
  icon?: LucideIcon
  className?: string
  disabled?: boolean
  type?: 'button' | 'submit'
}) {
  return (
    <button className={`button button-${variant} ${className}`} onClick={onClick} disabled={disabled} type={type}>
      {Icon && <Icon size={16} aria-hidden="true" />}
      <span>{children}</span>
    </button>
  )
}

function EmptyState({ view, onAction }: { view: EmptyViewModel; onAction?: () => void }) {
  const Icon = view.icon
  return (
    <div className="empty-state">
      <div className="empty-icon"><Icon size={22} strokeWidth={1.7} /></div>
      <h3>{view.title}</h3>
      <p>{view.description}</p>
      {view.action && <Button variant="secondary" icon={ArrowRight} onClick={onAction}>{view.action}</Button>}
    </div>
  )
}

function StatCard({ label, helper, icon: Icon, tone = 'teal' }: { label: string; helper: string; icon: LucideIcon; tone?: string }) {
  return (
    <article className={`stat-card stat-${tone}`}>
      <div className="stat-icon"><Icon size={18} /></div>
      <div>
        <p className="eyebrow">{label}</p>
        <strong className="stat-value">—</strong>
        <p className="stat-helper">{helper}</p>
      </div>
    </article>
  )
}

function Panel({ title, description, action, children, className = '' }: { title: string; description?: string; action?: ReactNode; children: ReactNode; className?: string }) {
  return (
    <section className={`panel ${className}`}>
      <div className="panel-heading">
        <div>
          <h2>{title}</h2>
          {description && <p>{description}</p>}
        </div>
        {action}
      </div>
      {children}
    </section>
  )
}

function Timeline({ events }: { events: TimelineEvent[] }) {
  return (
    <div className="thread-timeline">
      {events.map((event) => (
        <div className="thread-event" key={`${event.title}-${event.time}`}>
          <div className={`thread-node thread-${event.tone ?? 'muted'}`}><span /></div>
          <div className="thread-copy">
            <div className="thread-topline"><strong>{event.title}</strong><time>{event.time}</time></div>
            <p>{event.detail}</p>
            <span className="thread-actor">{event.actor}</span>
          </div>
        </div>
      ))}
    </div>
  )
}

function Legend() {
  const statuses: StatusKind[] = ['Waiting for material', 'Awaiting inspection', 'QC hold', 'Accepted', 'Dispatched', 'Estimated']
  return (
    <div className="status-legend" aria-label="Status legend">
      <span className="legend-title">Legend</span>
      {statuses.map((status) => <StatusChip key={status} status={status} compact />)}
    </div>
  )
}

function EmptyTable({ columns, title, detail, action, onAction }: { columns: string[]; title: string; detail: string; action?: string; onAction?: () => void }) {
  return (
    <div className="table-wrap">
      <table>
        <thead><tr>{columns.map((column) => <th key={column}>{column}</th>)}</tr></thead>
        <tbody>
          <tr><td colSpan={columns.length}><EmptyState view={{ title, description: detail, action, actionPath: '', icon: FileSearch }} onAction={onAction} /></td></tr>
        </tbody>
      </table>
    </div>
  )
}

function QueryCardView({ card, onNavigate }: { card: QueryCard; onNavigate: (path: string) => void }) {
  const Icon = card.icon
  return (
    <article className={`query-card query-${card.tone ?? 'indigo'}`}>
      <div className="query-icon"><Icon size={18} /></div>
      <div className="query-copy"><h3>{card.title}</h3><p>{card.description}</p></div>
      <button className="icon-button query-action" aria-label={card.action} title={card.action} onClick={() => card.path && onNavigate(card.path)}><ArrowRight size={17} /></button>
    </article>
  )
}

function CommandCentre({ onNavigate }: { onNavigate: (path: string) => void }) {
  const cards: QueryCard[] = [
    { title: 'Exception inbox', description: 'No open exceptions returned by the current query.', action: 'Open exceptions', path: '/exceptions', icon: AlertTriangle, tone: 'warning' },
    { title: 'Approvals waiting', description: 'Approval requests will appear here when the queue is connected.', action: 'Open approvals', path: '/approvals', icon: CheckCircle2, tone: 'teal' },
    { title: 'Tasks due', description: 'No task rows are available for this workspace yet.', action: 'Open tasks', path: '/tasks', icon: LayoutList, tone: 'indigo' },
  ]
  return (
    <>
      <div className="hero-row">
        <div><p className="eyebrow">Factory control room</p><h1>Command centre</h1><p className="lead">One place to see what needs attention next. Every metric below is query-ready and stays honest while the ledger is empty.</p></div>
        <div className="hero-actions"><Button variant="primary" icon={Sparkles} onClick={() => onNavigate('/orders')}>Create order</Button><Button icon={RefreshCcw} onClick={() => undefined}>Refresh view</Button></div>
      </div>
      <div className="callout callout-info"><Info size={17} /><div><strong>Connected to a clean workspace</strong><p>No operational rows have been returned. Connect the parent Supabase queries to populate this view; demo mode never invents KPI values.</p></div><StatusChip status="Demo data" compact /></div>
      <div className="stat-grid">
        <StatCard label="Open exceptions" helper="Awaiting a live exception query" icon={AlertTriangle} tone="warning" />
        <StatCard label="Orders in flight" helper="Awaiting an orders query" icon={LayoutList} tone="indigo" />
        <StatCard label="Dispatch ready" helper="Eligible rolls only, when queried" icon={PackageCheck} tone="teal" />
        <StatCard label="Quality holds" helper="Awaiting QC hold query" icon={ShieldAlert} tone="danger" />
      </div>
      <div className="two-column command-grid">
        <Panel title="What needs attention" description="Actionable queues open the exact record and next step.">
          <div className="query-grid">{cards.map((card) => <QueryCardView key={card.title} card={card} onNavigate={onNavigate} />)}</div>
        </Panel>
        <Panel title="Shift signal" description="Current-shift context is shown only after it is synced.">
          <div className="empty-signal"><div className="signal-ring"><Clock3 size={22} /></div><div><strong>Shift not synced</strong><p>Connect shift roster data to show work date, handover and machine readiness.</p><StatusChip status="Not configured" compact /></div></div>
        </Panel>
      </div>
      <div className="two-column">
        <Panel title="Production pulse" description="No chart is rendered until a real denominator and date range are available.">
          <EmptyState view={{ title: 'No production events yet', description: 'When operations are recorded, this panel will show target versus actual with unit, date range and drill-through.', action: 'Open operations', icon: Radio }} onAction={() => onNavigate('/operations')} />
        </Panel>
        <Panel title="Recent activity" description="Append-only events from the audit and operations feeds.">
          <EmptyState view={{ title: 'No events to review', description: 'The latest activity stream will appear here without sample rows.', action: 'Open audit log', icon: Clock3 }} onAction={() => onNavigate('/admin/audit')} />
        </Panel>
      </div>
    </>
  )
}

function LandingView({ role, path, onNavigate }: { role: Role; path: string; onNavigate: (path: string) => void }) {
  const meta = roleMeta[role]
  const nav = navByRole[role]
  const label = nav.find((item) => item.path === path)?.label ?? meta.label
  const action = role === 'machine_operator' ? 'Scan machine' : role === 'quality_inspector' ? 'Scan roll' : role === 'dispatch_officer' ? 'Scan manifest' : role === 'storekeeper' ? 'Record receipt' : 'Create first record'
  const actionPath = role === 'machine_operator' ? '/scan-machine' : role === 'quality_inspector' ? '/quality/scan' : role === 'dispatch_officer' ? '/dispatch/scan' : role === 'storekeeper' ? '/stores/receipts' : path
  return (
    <>
      <div className="hero-row">
        <div><p className="eyebrow">{meta.descriptor}</p><h1>{label}</h1><p className="lead">A focused workspace for {meta.label.toLowerCase()}. Start with today's work, then follow the record through its controlled state changes.</p></div>
        <div className="hero-actions"><Button variant="primary" icon={role === 'machine_operator' || role === 'quality_inspector' || role === 'dispatch_officer' ? ScanLine : Sparkles} onClick={() => onNavigate(actionPath)}>{action}</Button><Button icon={Download} onClick={() => undefined}>Export view</Button></div>
      </div>
      <div className="stat-grid">
        <StatCard label="Today's work" helper="No rows returned for this role" icon={Clock3} tone="teal" />
        <StatCard label="Needs attention" helper="Waiting for an exception query" icon={AlertCircle} tone="warning" />
        <StatCard label="In progress" helper="No workflow records yet" icon={RefreshCcw} tone="indigo" />
        <StatCard label="Completed" helper="No completion events returned" icon={CheckCircle2} tone="teal" />
      </div>
      <Panel title="Start with a record" description="The shell is ready for live queries; no business writes happen from this demo surface." action={<StatusChip status="No records yet" compact />}>
        <EmptyState view={{ title: `No ${label.toLowerCase()} records yet`, description: 'Connect the parent service hook to load real rows. Empty states are intentional and do not represent simulated business activity.', action, actionPath, icon: FileSearch }} onAction={() => onNavigate(actionPath)} />
      </Panel>
      <div className="two-column">
        <Panel title="Quick links" description="Permission-filtered sections for this role.">
          <div className="quick-links">{nav.slice(0, 4).map((item) => <button key={item.path} className="quick-link" onClick={() => onNavigate(item.path)}><item.icon size={17} /><span>{item.label}</span><ChevronRight size={16} /></button>)}</div>
        </Panel>
        <Panel title="Sync status" description="A write is never claimed until the server confirms it.">
          <div className="sync-card"><div className="sync-dot" /><div><strong>Ready for a live connection</strong><p>{dataService.connectionLabel}. Queries and RPC actions can be wired by the parent service layer.</p></div></div>
        </Panel>
      </div>
    </>
  )
}

function TableScreen({ title, description, columns, action, onAction, status }: { title: string; description: string; columns: string[]; action?: string; onAction?: () => void; status?: StatusKind }) {
  return (
    <>
      <div className="hero-row"><div><p className="eyebrow">Ledger view</p><h1>{title}</h1><p className="lead">{description}</p></div><div className="hero-actions">{action && <Button variant="primary" icon={Sparkles} onClick={onAction}>{action}</Button>}<Button icon={Download} onClick={() => undefined}>Export CSV</Button></div></div>
      <Panel title="Query results" description="Sticky headers, saved filters and review-before-commit are ready for the live adapter." action={<div className="panel-tools"><Button variant="quiet" icon={Filter}>Filters</Button><Button variant="quiet" icon={SlidersHorizontal}>Columns</Button>{status && <StatusChip status={status} compact />}</div>}>
        <EmptyTable columns={columns} title="No records returned" detail="This is an honest empty state. The page will populate from a permission-scoped query once the parent wires the service hook." action={action} onAction={onAction} />
      </Panel>
    </>
  )
}

function ScanScreen({ kind, onNavigate }: { kind: 'roll' | 'machine' | 'manifest'; onNavigate: (path: string) => void }) {
  const title = kind === 'roll' ? 'Scan roll' : kind === 'machine' ? 'Scan machine' : 'Scan manifest'
  const context = kind === 'roll' ? 'Quality gate' : kind === 'machine' ? 'Floor action' : 'Dispatch control'
  return (
    <>
      <div className="hero-row"><div><p className="eyebrow">{context}</p><h1>{title}</h1><p className="lead">Scan-first workflows open the record and show its current live state before any action is considered.</p></div><StatusChip status="No records yet" /></div>
      <div className="scan-layout"><Panel title="Scanner" description="Camera access is not enabled in this shell. No scan is treated as successful until a real adapter confirms it.">
        <div className="scan-box"><div className="scan-frame"><QrCode size={48} strokeWidth={1.4} /><div className="scan-corners" /></div><h3>Ready to scan</h3><p>Use a camera-enabled adapter or enter an identifier manually as a fallback.</p><Button variant="primary" icon={ScanLine} onClick={() => undefined}>Open scanner</Button></div>
      </Panel><Panel title="Manual fallback" description="Use a stable identifier from the label when camera access is unavailable.">
        <div className="manual-form"><label htmlFor="scan-id">{kind === 'roll' ? 'Roll ID or QR token' : kind === 'machine' ? 'Machine code' : 'Shipment or roll code'}</label><div className="input-with-icon"><Search size={17} /><input id="scan-id" placeholder="Enter an ID to query" /></div><Button icon={ArrowRight} onClick={() => undefined}>Find record</Button><div className="callout callout-muted"><Info size={16} /><p>Finding a record does not change its state. The next allowed action will be shown after a server query.</p></div></div>
      </Panel></div>
      <div className="scan-footer"><Button variant="quiet" onClick={() => onNavigate('/')}>Back to workspace</Button><StatusChip status="Not configured" compact /></div>
    </>
  )
}

function PassportScreen({ token }: { token: string }) {
  const events: TimelineEvent[] = []
  return (
    <>
      <div className="hero-row"><div><p className="eyebrow">Traceability record</p><h1>Roll passport</h1><p className="lead">A single, append-only view of identity, genealogy, quality and shipment state.</p></div><div className="hero-actions"><StatusChip status="No records yet" /><Button icon={Download} onClick={() => undefined}>Print label sheet</Button></div></div>
      <div className="passport-header"><div className="passport-code"><QrCode size={30} /><div><span className="eyebrow">Requested token</span><strong>{token || 'No token supplied'}</strong></div></div><div className="passport-state"><StatusChip status="Awaiting inspection" /><p>Eligibility is always re-verified from live data.</p></div></div>
      <div className="passport-grid"><Panel title="Identity & genealogy" description="Stable identifiers stay visible at every hand-off."><EmptyState view={{ title: 'Roll identity not found', description: 'Enter a valid roll token or connect the roll passport query to reveal batch, product route, operation history and location.', action: 'Scan a roll', icon: QrCode }} /></Panel><Panel title="Inspection history" description="Original results are append-only; corrections become new records."><EmptyState view={{ title: 'No inspections returned', description: 'Quality records will appear here when the roll identifier resolves.', icon: ShieldAlert }} /></Panel></div>
      <Panel title="Thread timeline" description="Warp line with weft nodes for every recorded milestone.">{events.length ? <Timeline events={events} /> : <EmptyState view={{ title: 'No timeline events yet', description: 'The timeline stays empty until real production, inspection or shipment events are returned.', icon: RefreshCcw }} />}</Panel>
    </>
  )
}

function OrderTimeline() {
  const events: TimelineEvent[] = []
  return <Panel title="Order thread" description="Buyer, planning, production and dispatch milestones in one traceable thread." action={<StatusChip status="Estimated" compact />}><div className="order-thread-intro"><div className="order-token"><span className="eyebrow">Order ID</span><strong>Awaiting selection</strong></div><p>Estimated completion is shown only with its factors: material readiness, route duration, machine availability and quality queue.</p></div>{events.length ? <Timeline events={events} /> : <EmptyState view={{ title: 'Choose an order to see the thread', description: 'No order rows are available in this workspace. Open an order from the live query when connected.', action: 'Open orders', icon: RefreshCcw }} />}</Panel>
}

function PayrollScreen() {
  return <>
    <div className="hero-row"><div><p className="eyebrow">People operations</p><h1>Payroll periods</h1><p className="lead">Prepare reviewable payroll drafts from recorded attendance and approved corrections.</p></div><Button variant="primary" icon={Sparkles} onClick={() => undefined}>Start a draft</Button></div>
    <div className="callout callout-warning"><AlertTriangle size={18} /><div><strong>Prototype disclaimer</strong><p>Payroll calculations are configurable examples only and are <strong>not statutory compliant</strong>. No payroll is finalised or paid from this frontend shell.</p></div><StatusChip status="Demo data" compact /></div>
    <Panel title="Payroll periods" description="A live query will show status, work date range, approvals and source attendance. Changes belong to an RPC with audit history."><EmptyTable columns={['Period', 'Work date', 'Draft status', 'Source rows', 'Owner']} title="No payroll periods yet" detail="Create a draft only after the parent connects the attendance and payroll RPCs. The empty state does not imply zero wages." action="Start a draft" /></Panel>
  </>
}

function FinanceScreen({ variance = false }: { variance?: boolean }) {
  return <>
    <div className="hero-row"><div><p className="eyebrow">Finance visibility</p><h1>{variance ? 'Variance cases' : 'Order costs'}</h1><p className="lead">Explainable costs only: actual values require a recorded source line, while estimates keep their factors visible.</p></div><div className="hero-actions"><Button variant="primary" icon={Sparkles} onClick={() => undefined}>{variance ? 'Review a case' : 'Open cost summary'}</Button><StatusChip status="Estimated" /></div></div>
    <div className="callout callout-muted"><Info size={17} /><p>Invoices in this prototype are drafts/internal references. No automatic payments, bank transfers or audited profit claims are made here.</p></div>
    <div className="stat-grid"><StatCard label="Actual cost lines" helper="Only backed by source records" icon={Database} tone="indigo" /><StatCard label="Open variance cases" helper="Threshold is configurable" icon={AlertTriangle} tone="warning" /><StatCard label="Draft invoices" helper="Internal reference only" icon={FileSearch} tone="teal" /><StatCard label="Approved expenses" helper="Awaiting an expense query" icon={CheckCircle2} tone="teal" /></div>
    <Panel title={variance ? 'Variance queue' : 'Cost summaries'} description="Every amount will link back to its source record, unit and currency."><EmptyTable columns={variance ? ['Case', 'Order', 'Threshold', 'Source lines', 'Status'] : ['Order', 'Currency', 'Actual', 'Estimated', 'Variance']} title="No finance records returned" detail="Connect the finance views to populate this table. Values are intentionally not fabricated." action={variance ? 'Open costing' : 'Open orders'} /></Panel>
  </>
}

function DispatchBoard() {
  const lanes = ['Queued', 'In progress', 'Blocked']
  return <>
    <div className="hero-row"><div><p className="eyebrow">Production planning</p><h1>Dispatch board</h1><p className="lead">Machine lanes keep material readiness, setup, due date and deterministic schedule recommendations visible.</p></div><div className="hero-actions"><Button variant="primary" icon={Sparkles} onClick={() => undefined}>Suggest schedule</Button><StatusChip status="Estimated" /></div></div>
    <div className="callout callout-info"><Sparkles size={17} /><p><strong>Recommendation mode is deterministic.</strong> Suggestions will rank due date, priority, setup reduction, machine capability and material readiness. Accepting one will require a server-side assignment RPC.</p></div>
    <div className="board-grid">{lanes.map((lane) => <section className="board-lane" key={lane}><div className="lane-heading"><h2>{lane}</h2><span className="count-badge">—</span></div><EmptyState view={{ title: `No ${lane.toLowerCase()} operations`, description: 'The lane will populate from permission-scoped operation assignments.', icon: Grid2X2 }} /></section>)}</div>
  </>
}

function PermissionDenied({ role, onNavigate }: { role: Role; onNavigate: (path: string) => void }) {
  return <Panel title="Permission required" description="This route is not available to the selected demo role."><EmptyState view={{ title: 'Access is intentionally limited', description: `The ${roleMeta[role].label.toLowerCase()} navigation does not include this record. Ask an administrator for the required permission, or return to your landing page.`, action: 'Return to landing', icon: ShieldAlert }} onAction={() => onNavigate(roleMeta[role].landing)} /></Panel>
}

function Screen({ role, path, onNavigate }: { role: Role; path: string; onNavigate: (path: string) => void }) {
  const livePaths = ['/command-centre','/orders','/plans','/operations','/shift-board','/my-jobs','/stores','/inventory/shortages','/stores/ledger','/stores/reservations','/stores/quarantine','/stores/receipts','/stores/adjustments','/stores/counts','/stores/rfq','/quality/queue','/quality/holds','/quality/rework','/quality/incidents','/quality/defects','/quality/plans','/quality/scan','/dispatch/ready','/dispatch/rolls','/dispatch/drafts','/dispatch/scan','/dispatch/history','/dispatch/documents','/machines','/maintenance','/handover','/tasks','/exceptions','/approvals','/admin/users','/admin/roles','/admin/settings','/admin/reconciliation','/admin/automations','/admin/integrations','/admin/audit','/hr/attendance','/hr/roster','/hr/skills','/hr/payroll','/hr/corrections','/hr/reports','/finance/orders','/finance/variance','/finance/entries','/finance/invoices','/finance/expenses','/finance/exports','/reports','/notifications','/wip','/dispatch-board','/record-output','/scan-machine','/report-issue','/portal','/portal/timeline','/portal/documents','/portal/changes']
  if (livePaths.includes(path)) return <LivePage path={path} role={role} onNavigate={onNavigate} />
  if (path === '/command-centre') return <CommandCentre onNavigate={onNavigate} />
  if (path.startsWith('/r/')) return <PassportScreen token={path.slice(3)} />
  if (path === '/portal/timeline' || path === '/orders/order') return <><div className="hero-row"><div><p className="eyebrow">Traceability first</p><h1>Order timeline</h1><p className="lead">A conversation and milestone thread for one order.</p></div><Button icon={ArrowRight} onClick={() => onNavigate('/orders')}>Back to orders</Button></div><OrderTimeline /></>
  if (path === '/dispatch-board') return <DispatchBoard />
  if (path === '/record-output') return <TableScreen title="Record output" description="Capture good, waste and reject quantities against an assigned operation. A server RPC will enforce idempotency, units and shift close rules." columns={['Operation', 'Shift', 'Good qty', 'Waste', 'State']} action="Scan machine" onAction={() => onNavigate('/scan-machine')} status="Actual" />
  if (path === '/quality/scan') return <ScanScreen kind="roll" onNavigate={onNavigate} />
  if (path === '/scan-machine') return <ScanScreen kind="machine" onNavigate={onNavigate} />
  if (path === '/dispatch/scan') return <ScanScreen kind="manifest" onNavigate={onNavigate} />
  if (path === '/hr/payroll') return <PayrollScreen />
  if (path === '/finance/orders') return <FinanceScreen />
  if (path === '/finance/variance') return <FinanceScreen variance />
  if (path === '/portal') return <TableScreen title="My orders" description="Buyer-scoped orders, status and next actions. Documents and change requests remain linked to the order thread." columns={['Order', 'Product', 'Requested date', 'Status', 'Next step']} action="Request a new order" status="Estimated" />
  if (path === '/admin/users') return <TableScreen title="Users & approvals" description="Review access requests and user status without exposing secrets. Approval decisions belong to audited RPCs." columns={['Person', 'Role', 'Status', 'Last sign-in', 'MFA']} action="Invite a user" />
  if (path.includes('/quality')) return <TableScreen title={path.includes('holds') ? 'Quality holds' : path.includes('rework') ? 'Rework queue' : path.includes('defects') ? 'Defect analytics' : 'Inspection queue'} description="Quality gates keep uninspected, quarantined and rejected rolls out of dispatch." columns={['Roll / batch', 'Checkpoint', 'State', 'Assigned to', 'Next step']} action="Scan roll" onAction={() => onNavigate('/quality/scan')} status="Awaiting inspection" />
  if (path.includes('/dispatch')) return <TableScreen title={path.includes('history') ? 'Dispatch history' : path.includes('rolls') ? 'Eligible rolls' : 'Dispatch readiness'} description="Only quality-accepted rolls can be allocated and confirmed. Mismatches must be visible before confirmation." columns={['Shipment / roll', 'Order', 'Quality state', 'Location', 'Eligibility']} action="Scan manifest" onAction={() => onNavigate('/dispatch/scan')} status="Accepted" />
  if (path.includes('/stores') || path.includes('/inventory')) return <TableScreen title={path.includes('shortages') ? 'Inventory shortages' : path.includes('receipts') ? 'Receipts' : 'Stock by location'} description="Balances derive from an append-only movement ledger with accepted, quarantined, reserved and expected quantities." columns={['Item / batch', 'Location', 'Available', 'Reserved', 'Quarantined']} action={path.includes('receipts') ? 'Record receipt' : 'Open shortages'} status="Allocated" />
  if (path.includes('/hr/')) return <TableScreen title={path.includes('attendance') ? 'Attendance' : path.includes('roster') ? 'Roster' : 'People operations'} description="Attendance, skills and corrections remain reviewable inputs to payroll drafts." columns={['Employee', 'Work date', 'Shift', 'State', 'Approval']} action="Add attendance" />
  if (path.includes('/finance/')) return <FinanceScreen variance={path.includes('variance')} />
  if (path.includes('/exceptions')) return <TableScreen title="Exception inbox" description="Each exception explains what failed, why it matters and the next safe action." columns={['Exception', 'Record', 'Severity', 'Age', 'Next step']} action="Refresh inbox" status="QC hold" />
  if (path.includes('/approvals')) return <TableScreen title="Approvals" description="Review requests with separation-of-duties checks and an auditable decision trail." columns={['Request', 'Record', 'Requester', 'Due', 'Decision']} action="Refresh queue" />
  if (path.includes('/tasks')) return <TableScreen title="Tasks" description="Operational work items route to the responsible role with a clear record and next step." columns={['Task', 'Record', 'Owner', 'Due', 'State']} action="Create task" />
  if (path.includes('/admin/')) return <TableScreen title={path.includes('audit') ? 'Audit log' : path.includes('roles') ? 'Roles & permissions' : path.includes('integration') ? 'Integration health' : 'Settings'} description="Configuration is explicit, permission-scoped and ready for a parent service adapter." columns={['Record', 'Owner', 'State', 'Updated', 'Next step']} action="Refresh view" />
  if (path === '/my-jobs') return <LandingView role={role} path={path} onNavigate={onNavigate} />
  return <LandingView role={role} path={path} onNavigate={onNavigate} />
}

function App() {
  const { bootstrap, signOut } = useAuth()
  const assignedRoles = useMemo(() => (bootstrap?.roles ?? []).filter((value): value is Role => roleOptions.includes(value as Role)), [bootstrap])
  const preferredRole = sessionStorage.getItem('everest-role') as Role | null
  const initialRole = assignedRoles.includes(preferredRole as Role) ? preferredRole as Role : assignedRoles[0] ?? 'factory_manager'
  const [role, setRole] = useState<Role>(initialRole)
  const [path, setPath] = useState(() => getRouteFromHash(roleMeta[role].landing))
  const [railOpen, setRailOpen] = useState(true)
  const [searchOpen, setSearchOpen] = useState(false)
  const [notificationsOpen, setNotificationsOpen] = useState(false)
  const [profileOpen, setProfileOpen] = useState(false)
  const [toast, setToast] = useState('')

  useEffect(() => {
    if (assignedRoles.length && !assignedRoles.includes(role)) setRole(assignedRoles[0])
  }, [assignedRoles, role])

  useEffect(() => {
    const syncRoute = () => setPath(getRouteFromHash(roleMeta[role].landing))
    window.addEventListener('hashchange', syncRoute)
    return () => window.removeEventListener('hashchange', syncRoute)
  }, [role])

  useEffect(() => {
    const onKeyDown = (event: KeyboardEvent) => {
      if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === 'k') {
        event.preventDefault()
        setSearchOpen(true)
      }
      if (event.key === 'Escape') {
        setSearchOpen(false)
        setNotificationsOpen(false)
        setProfileOpen(false)
      }
    }
    window.addEventListener('keydown', onKeyDown)
    return () => window.removeEventListener('keydown', onKeyDown)
  }, [])

  useEffect(() => {
    if (!toast) return
    const timer = window.setTimeout(() => setToast(''), 3200)
    return () => window.clearTimeout(timer)
  }, [toast])

  const nav = navByRole[role].filter((item) => !routePermissions[item.path] || bootstrap?.permissions.includes(routePermissions[item.path]))
  const current = nav.find((item) => item.path === path)
  const title = current?.label ?? (path === '/r/' ? 'Roll passport' : roleMeta[role].label)
  const isFloor = floorRoles.includes(role)
  const visibleBottomNav = nav.slice(0, 4)
  const navigate = (nextPath: string) => {
    const destination = nextPath === '/' ? roleMeta[role].landing : nextPath
    window.location.hash = destination
    setPath(destination)
    setSearchOpen(false)
    setNotificationsOpen(false)
    setProfileOpen(false)
  }
  const changeRole = (nextRole: Role) => {
    if (!assignedRoles.includes(nextRole)) return
    setRole(nextRole)
    sessionStorage.setItem('everest-role', nextRole)
    navigate(roleMeta[nextRole].landing)
  }
  const notify = (message: string) => setToast(message)
  const roleLabel = roleMeta[role].label
  const searchItems = useMemo(() => nav.map((item) => ({ ...item, role: roleLabel })), [nav, roleLabel])
  const deepLinkPermission = routePermissions[path] ?? (path.startsWith('/r/') ? 'rolls.read' : path === '/orders/order' ? 'orders.read' : path === '/portal/timeline' ? 'buyer.portal' : undefined)
  const routeAllowed = (!deepLinkPermission || Boolean(bootstrap?.permissions.includes(deepLinkPermission))) && (nav.some((item) => item.path === path) || (path.startsWith('/r/') && Boolean(bootstrap?.permissions.includes('rolls.read'))) || (path === '/orders/order' && Boolean(bootstrap?.permissions.includes('orders.read'))) || (path === '/portal/timeline' && Boolean(bootstrap?.permissions.includes('buyer.portal'))))

  return (
    <div className={`app-shell ${railOpen ? '' : 'rail-collapsed'}`}>
      <aside className="sidebar" aria-label="Primary navigation">
        <div className="brand-block"><div className="brand-mark"><span>ET</span></div>{railOpen && <div className="brand-copy"><strong>Everest Textile</strong><span>Workshop ledger</span></div>}</div>
        <div className="demo-badge"><span className="demo-dot" />{railOpen ? 'PREVIEW · authenticated' : 'PREVIEW'}</div>
        <div className="workspace-caption">{railOpen ? 'Workspace' : '—'}</div>
        <nav className="side-nav">{nav.map((item) => <NavLink key={item.path} item={item} active={item.path === path} expanded={railOpen} onClick={() => navigate(item.path)} />)}</nav>
        <div className="sidebar-bottom">{railOpen && <div className="rail-note"><span className="sync-dot" /><div><strong>Sync ready</strong><span>{dataService.isConfigured ? 'Supabase available' : 'Waiting for adapter'}</span></div></div>}<button className="rail-toggle" onClick={() => setRailOpen((open) => !open)} aria-label={railOpen ? 'Collapse navigation' : 'Expand navigation'}>{railOpen ? <PanelLeftClose size={18} /> : <PanelLeftOpen size={18} />}<span>{railOpen ? 'Collapse rail' : 'Expand rail'}</span></button></div>
      </aside>
      <main className="main-area">
        <header className="topbar">
          <div className="topbar-start"><button className="mobile-menu icon-button" onClick={() => setRailOpen((open) => !open)} aria-label="Toggle navigation"><Menu size={20} /></button><div className="breadcrumb"><span>Everest Textile</span><ChevronRight size={14} /><strong>{title}</strong></div></div>
          <div className="topbar-actions"><button className="global-search" onClick={() => setSearchOpen(true)} aria-label="Open global search"><Search size={17} /><span>Search records</span><kbd><Command size={12} />K</kbd></button><div className="shift-indicator"><span className="shift-pulse" /><span>Shift context</span><strong>Not synced</strong></div><div className="topbar-popover-wrap"><button className="icon-button notification-button" onClick={() => { setNotificationsOpen((open) => !open); setProfileOpen(false) }} aria-label="Notifications"><Bell size={19} /><span className="notification-dot" /></button>{notificationsOpen && <div className="popover notification-popover"><div className="popover-heading"><div><strong>Notifications</strong><span>In-app feed</span></div><button className="icon-button" onClick={() => setNotificationsOpen(false)} aria-label="Close notifications"><X size={16} /></button></div><EmptyState view={{ title: 'Nothing new', description: 'Notifications will appear when real events are returned.', icon: Bell }} /></div>}</div><div className="topbar-popover-wrap"><button className="profile-trigger" onClick={() => { setProfileOpen((open) => !open); setNotificationsOpen(false) }}><span className="avatar">{roleMeta[role].initials}</span><span className="profile-name">{roleLabel}</span><ChevronDown size={15} /></button>{profileOpen && <div className="popover profile-popover"><div className="profile-summary"><span className="avatar avatar-large">{roleMeta[role].initials}</span><div><strong>{roleLabel}</strong><span>{bootstrap?.profile.email ?? 'Authenticated user'}</span></div></div><label className="role-select-label" htmlFor="role-switch">Assigned role</label><select id="role-switch" value={role} onChange={(event) => changeRole(event.target.value as Role)}>{assignedRoles.map((option) => <option value={option} key={option}>{roleMeta[option].label}</option>)}</select><button className="popover-link" onClick={() => notify('Profile settings are ready for the parent auth adapter.')}>Profile & sessions <ArrowRight size={15} /></button><button className="popover-link" onClick={() => void signOut()}>Sign out <ArrowRight size={15} /></button></div>}</div></div>
        </header>
        <div className="content-wrap"><div className="preview-notice"><strong>Demo preview</strong><span>Seeded records are synthetic. Successful workflow actions may update this demo Supabase project.</span></div><div className="content-header"><div><span className="route-caption">{roleLabel} · <span>DEMO</span></span><h2 className="mobile-page-title">{title}</h2></div><div className="connection-state"><span className="online-dot" />{dataService.isConfigured ? 'Online · Supabase available' : 'Ready · not connected'}</div></div><Legend /><div className="page-content">{routeAllowed ? <Screen role={role} path={path} onNavigate={navigate} /> : <PermissionDenied role={role} onNavigate={navigate} />}</div></div>
      </main>
      {isFloor && <nav className="bottom-nav" aria-label="Floor navigation">{visibleBottomNav.map((item) => <NavLink key={item.path} item={item} active={item.path === path} expanded onClick={() => navigate(item.path)} bottom />)}</nav>}
      {searchOpen && <div className="overlay" role="presentation" onMouseDown={(event) => { if (event.currentTarget === event.target) setSearchOpen(false) }}><div className="search-dialog" role="dialog" aria-modal="true" aria-label="Global search"><div className="search-dialog-head"><Search size={19} /><input autoFocus placeholder="Search orders, rolls, batches, machines…" /><kbd>ESC</kbd></div><div className="search-dialog-body"><div className="search-scope"><span>Search this workspace</span><StatusChip status="No records yet" compact /></div><div className="search-results">{searchItems.slice(0, 6).map((item) => <button className="search-result" key={item.path} onClick={() => navigate(item.path)}><item.icon size={17} /><span><strong>{item.label}</strong><small>{item.path}</small></span><ArrowRight size={15} /></button>)}</div><p className="search-foot"><Keyboard size={14} /> Use Ctrl K anytime to open search</p></div></div></div>}
      {toast && <div className="toast" role="status"><CheckCircle2 size={17} /><span>{toast}</span><button className="icon-button" onClick={() => setToast('')} aria-label="Dismiss message"><X size={14} /></button></div>}
    </div>
  )
}

function NavLink({ item, active, expanded, onClick, bottom = false }: { item: NavItem; active: boolean; expanded: boolean; onClick: () => void; bottom?: boolean }) {
  const Icon = item.icon
  return <button className={`nav-link ${active ? 'active' : ''} ${bottom ? 'bottom-link' : ''}`} onClick={onClick} title={!expanded ? item.label : undefined} aria-current={active ? 'page' : undefined}><Icon size={18} strokeWidth={active ? 2.2 : 1.8} /><span>{expanded ? item.label : item.label.slice(0, 2)}</span>{active && expanded && <span className="nav-active-mark" />}</button>
}

export default App
