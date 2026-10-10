import type { LucideIcon } from 'lucide-react'

export type Role =
  | 'system_admin'
  | 'factory_manager'
  | 'production_supervisor'
  | 'machine_operator'
  | 'storekeeper'
  | 'quality_inspector'
  | 'dispatch_officer'
  | 'hr_payroll_officer'
  | 'finance_officer'
  | 'buyer'

export type NavItem = {
  label: string
  path: string
  icon: LucideIcon
  permission?: string
}

export type TimelineEvent = {
  title: string
  detail: string
  actor: string
  time: string
  tone?: 'teal' | 'warning' | 'danger' | 'muted'
}

export type QueryCard = {
  title: string
  description: string
  action: string
  path?: string
  icon: LucideIcon
  tone?: 'teal' | 'warning' | 'danger' | 'indigo'
}

export type EmptyViewModel = {
  title: string
  description: string
  action?: string
  actionPath?: string
  icon: LucideIcon
}

export type StatusKind =
  | 'Waiting for material'
  | 'QC hold'
  | 'Awaiting inspection'
  | 'Rework required'
  | 'Accepted'
  | 'Reserved for shipment'
  | 'Dispatched'
  | 'Breakdown'
  | 'Planned maintenance'
  | 'Simulated'
  | 'Demo data'
  | 'Estimated'
  | 'Allocated'
  | 'Actual'
  | 'Ready'
  | 'No records yet'
  | 'Not configured'

export type DataState = 'empty' | 'loading' | 'ready' | 'error'
