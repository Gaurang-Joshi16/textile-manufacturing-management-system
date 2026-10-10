import { useCallback, useEffect, useRef, useState, type FormEvent } from 'react'
import { dataService } from './services/data'

type Row = Record<string, unknown>
type ScanKind = 'roll' | 'machine' | 'manifest'

function safeActionError(error: unknown) {
  const message = error instanceof Error ? error.message : ''
  const code = message.match(/CODE:\s*([A-Z0-9_]+)/)?.[1]
  if (!code) return 'The request was not completed. Check role access and current record state.'
  const known: Record<string, string> = {
    PERMISSION_DENIED: 'Your assigned role cannot perform this action.',
    OPERATION_NOT_ASSIGNED: 'This job is not assigned to your operator account.',
    OPERATION_NOT_READY: 'Start is allowed only after the job is assigned and ready.',
    SHIFT_CLOSED: 'The selected shift is closed; choose an open shift instance.',
    OUTPUT_QTY_INVALID: 'Enter a positive total across good, waste and reject quantities.',
    IDEMPOTENCY_KEY_REQUIRED: 'The request key is missing. Refresh and try again.',
    INVALID_STATE_TRANSITION: 'That machine transition is not allowed from its current state.',
    REASON_REQUIRED: 'Enter a short reason before reporting the issue.',
    MACHINE_UNAVAILABLE: 'That machine cannot be selected in its current state.',
    BATCH_NOT_AVAILABLE: 'The selected batch/location has no eligible stock for the request.',
  }
  return known[code] ?? `The server blocked the action (${code}). Review the record and permitted next step.`
}

export function ProductionOutputForm({ onSaved }: { onSaved: () => void }) {
  const client = dataService.getClient()
  const [operations, setOperations] = useState<Row[]>([])
  const [operationId, setOperationId] = useState('')
  const [instances, setInstances] = useState<Row[]>([])
  const [instanceId, setInstanceId] = useState('')
  const [qty, setQty] = useState({ good: '', waste: '0', reject: '0', wasteReason: '', rejectReason: '', notes: '' })
  const [loading, setLoading] = useState(true)
  const [working, setWorking] = useState(false)
  const [error, setError] = useState('')
  const [notice, setNotice] = useState('')
  const [result, setResult] = useState<Row | null>(null)
  const keyRef = useRef(crypto.randomUUID())

  useEffect(() => {
    let active = true
    if (!client) { setLoading(false); setError('Supabase is not configured.'); return }
    client.from('production_operations')
      .select('id,operation_no,stage,status,shift_id,planned_start,target_qty,unit')
      .in('status', ['IN_PROGRESS', 'PAUSED', 'READY'])
      .order('planned_start', { ascending: true })
      .eq('is_demo', true)
      .limit(50)
      .then(({ data, error }) => {
        if (!active) return
        if (error) setError(safeActionError(error))
        else {
          const rows = (data ?? []) as unknown as Row[]
          setOperations(rows)
          if (rows[0]?.id) setOperationId(String(rows[0].id))
        }
        setLoading(false)
      })
    return () => { active = false }
  }, [client])

  const selected = operations.find(row => String(row.id) === operationId)
  const loadInstances = useCallback(async () => {
    if (!client || !selected?.shift_id) { setInstances([]); setInstanceId(''); return }
    const workDate = String(selected.planned_start ?? '').slice(0, 10)
    if (!workDate) { setInstances([]); setInstanceId(''); return }
    const { data, error } = await client.from('shift_instances')
      .select('id,shift_id,work_date,status')
      .eq('shift_id', String(selected.shift_id))
      .eq('work_date', workDate)
      .eq('status', 'OPEN')
      .eq('is_demo', true)
      .limit(10)
    if (error) { setError(safeActionError(error)); setInstances([]); setInstanceId(''); return }
    const rows = (data ?? []) as unknown as Row[]
    setInstances(rows)
    setInstanceId(rows[0]?.id ? String(rows[0].id) : '')
  }, [client, selected?.shift_id, selected?.planned_start])

  useEffect(() => { void loadInstances() }, [loadInstances])

  async function submit(event: FormEvent) {
    event.preventDefault()
    if (!client || !selected || !instanceId) return
    setWorking(true); setError(''); setNotice(''); setResult(null)
    try {
      const { data, error } = await client.rpc('rpc_record_output', {
        p_operation_id: operationId,
        p_shift_instance_id: instanceId,
        p_good_qty: Number(qty.good || 0),
        p_waste_qty: Number(qty.waste || 0),
        p_reject_qty: Number(qty.reject || 0),
        p_unit: String(selected.unit ?? 'm'),
        p_idempotency_key: keyRef.current,
        p_waste_reason: Number(qty.waste || 0) > 0 ? qty.wasteReason : null,
        p_reject_reason: Number(qty.reject || 0) > 0 ? qty.rejectReason : null,
        p_notes: qty.notes,
      })
      if (error) throw error
      const response = data as Row
      setResult(response)
      const rolls = Array.isArray(response.rolls) ? response.rolls.length : 0
      setNotice(`Output recorded for ${String(selected.operation_no)}${rolls ? `; ${rolls} roll passport(s) created` : ''}.`)
      keyRef.current = crypto.randomUUID()
      setQty(v => ({ ...v, good: '', waste: '0', reject: '0', wasteReason: '', rejectReason: '', notes: '' }))
      onSaved()
    } catch (e) { setError(safeActionError(e)) }
    finally { setWorking(false) }
  }

  return <section className="live-panel live-action-panel">
    <h2>Record good, waste and reject output</h2>
    <p>Only operations visible to this signed-in role are selectable. The database validates assignment, route, unit, shift and idempotency.</p>
    {error && <div className="live-error" role="alert">{error}</div>}
    {notice && <div className="live-success" role="status">{notice}</div>}
    {loading ? <p className="live-empty">Loading assigned operations…</p> : operations.length === 0 ? <p className="live-empty">No READY, IN_PROGRESS or PAUSED operation is assigned to this account. Ask a supervisor to assign a rostered, skilled worker before recording output.</p> : <form className="live-form" onSubmit={submit}>
      <label>Operation<select required value={operationId} onChange={e => setOperationId(e.target.value)}>{operations.map(row => <option key={String(row.id)} value={String(row.id)}>{String(row.operation_no)} · {String(row.stage)} · {String(row.status)} · target {String(row.target_qty)} {String(row.unit)}</option>)}</select></label>
      <label>Open shift instance<select required value={instanceId} onChange={e => setInstanceId(e.target.value)}><option value="">Select an open shift</option>{instances.map(row => <option key={String(row.id)} value={String(row.id)}>{String(row.work_date)} · {String(row.status)}</option>)}</select></label>
      <label>Good quantity<input required type="number" min="0" step="0.001" value={qty.good} onChange={e => setQty(v => ({ ...v, good: e.target.value }))} /></label>
      <label>Waste quantity<input type="number" min="0" step="0.001" value={qty.waste} onChange={e => setQty(v => ({ ...v, waste: e.target.value }))} /></label>
      {Number(qty.waste) > 0 && <label>Waste reason<input required minLength={3} value={qty.wasteReason} onChange={e => setQty(v => ({ ...v, wasteReason: e.target.value }))} /></label>}
      <label>Reject quantity<input type="number" min="0" step="0.001" value={qty.reject} onChange={e => setQty(v => ({ ...v, reject: e.target.value }))} /></label>
      {Number(qty.reject) > 0 && <label>Reject reason<input required minLength={3} value={qty.rejectReason} onChange={e => setQty(v => ({ ...v, rejectReason: e.target.value }))} /></label>}
      <label className="live-form-wide">Notes<input value={qty.notes} onChange={e => setQty(v => ({ ...v, notes: e.target.value }))} /></label>
      <div className="live-form-actions"><span>Submitting may create traced roll passports. Retry is protected by an idempotency key.</span><button className="button button-primary" disabled={working || !instanceId}>{working ? 'Recording…' : 'Record output'}</button></div>
    </form>}
    {result && <details className="live-result"><summary>Server response details</summary><pre className="live-json">{JSON.stringify(result, null, 2)}</pre></details>}
  </section>
}

export function MachineIssueForm({ onSaved }: { onSaved: () => void }) {
  const client = dataService.getClient()
  const [machines, setMachines] = useState<Row[]>([])
  const [machineId, setMachineId] = useState('')
  const [reason, setReason] = useState('Synthetic demo breakdown: mechanical vibration requires inspection.')
  const [loading, setLoading] = useState(true)
  const [working, setWorking] = useState(false)
  const [error, setError] = useState('')
  const [notice, setNotice] = useState('')

  useEffect(() => {
    let active = true
    if (!client) { setLoading(false); setError('Supabase is not configured.'); return }
    client.from('machines').select('id,machine_code,name,status,location,is_active').eq('is_active', true).eq('source', 'DEMO').order('machine_code').limit(50)
      .then(({ data, error }) => {
        if (!active) return
        if (error) setError(safeActionError(error))
        else {
          const rows = (data ?? []) as unknown as Row[]
          setMachines(rows)
          const target = rows.find(row => ['IDLE', 'SETUP'].includes(String(row.status)))
          if (target?.id) setMachineId(String(target.id))
        }
        setLoading(false)
      })
    return () => { active = false }
  }, [client])

  const candidates = machines.filter(row => ['IDLE', 'SETUP'].includes(String(row.status)))
  async function report(event: FormEvent) {
    event.preventDefault()
    if (!client || reason.trim().length < 3) return
    setWorking(true); setError(''); setNotice('')
    try {
      const { data, error } = await client.rpc('rpc_set_machine_status', { p_machine_id: machineId, p_new_status: 'BREAKDOWN', p_reason: reason.trim() })
      if (error) throw error
      setNotice(`Breakdown recorded for ${String(data && typeof data === 'object' ? (data as Row).machine_id : 'machine')}. The server created linked downtime, task, exception and audit events.`)
      onSaved()
    } catch (e) { setError(safeActionError(e)) }
    finally { setWorking(false) }
  }

  return <section className="live-panel live-action-panel">
    <h2>Report machine issue</h2>
    <p>Creates an authorised BREAKDOWN transition with reason, downtime record, supervisor task, exception and audit event. This is synthetic demo activity.</p>
    {error && <div className="live-error" role="alert">{error}</div>}{notice && <div className="live-success" role="status">{notice}</div>}
    {loading ? <p className="live-empty">Loading machines…</p> : candidates.length === 0 ? <p className="live-empty">No IDLE or SETUP machine can transition to BREAKDOWN. The existing breakdown is already recorded or the current machine state needs review.</p> : <form className="live-form" onSubmit={report}>
      <label>Machine<select value={machineId} onChange={e => setMachineId(e.target.value)} required>{candidates.map(row => <option key={String(row.id)} value={String(row.id)}>{String(row.machine_code)} · {String(row.name)} · {String(row.status)}</option>)}</select></label>
      <label className="live-form-wide">Observed issue / reason<textarea required minLength={3} rows={3} value={reason} onChange={e => setReason(e.target.value)} /></label>
      <div className="live-form-actions"><span>Server role, transition and reason rules are authoritative.</span><button className="button button-primary" disabled={working || !machineId}>{working ? 'Submitting…' : 'Report breakdown'}</button></div>
    </form>}
  </section>
}

export function ScanLookup({ kind }: { kind: ScanKind }) {
  const client = dataService.getClient()
  const [code, setCode] = useState('')
  const [record, setRecord] = useState<Row | null>(null)
  const [error, setError] = useState('')
  const [working, setWorking] = useState(false)
  const [cameraError, setCameraError] = useState('')
  const videoRef = useRef<HTMLVideoElement>(null)
  const streamRef = useRef<MediaStream | null>(null)
  const timerRef = useRef<number | null>(null)

  const stopCamera = useCallback(() => {
    if (timerRef.current !== null) window.clearTimeout(timerRef.current)
    timerRef.current = null
    streamRef.current?.getTracks().forEach(track => track.stop())
    streamRef.current = null
  }, [])
  useEffect(() => () => stopCamera(), [stopCamera])

  async function find(event?: FormEvent) {
    event?.preventDefault()
    if (!client || !code.trim()) return
    setWorking(true); setError(''); setRecord(null)
    try {
      const needle = code.trim()
      let query
      if (kind === 'roll') {
        if (!/^[A-Za-z0-9_-]{3,160}$/.test(needle)) throw new Error('Enter a roll code or opaque QR token using letters, digits, hyphen or underscore.')
        query = client.from('fabric_rolls').select('id,roll_code,qr_token,qty,unit,status,current_stage,location_id,hold_reason,is_demo').or(`roll_code.eq.${needle},qr_token.eq.${needle}`).eq('is_demo', true).limit(1)
      } else if (kind === 'machine') {
        query = client.from('machines').select('id,machine_code,name,status,location,capacity_per_hour,capacity_unit,is_active').eq('machine_code', needle).eq('source', 'DEMO').limit(1)
      } else {
        query = client.from('shipments').select('id,shipment_number,status,order_id,manifest_expected_count,manifest_scanned_count,needs_attention,carrier,vehicle_no').eq('shipment_number', needle).eq('is_demo', true).limit(1)
      }
      const { data, error } = await query
      if (error) throw error
      const row = (data as unknown as Row[] | null)?.[0]
      if (!row) throw new Error('No accessible record matched that code. Check the identifier and your role scope.')
      setRecord(row)
    } catch (e) { setError(e instanceof Error ? e.message : 'Lookup failed.') }
    finally { setWorking(false) }
  }

  async function startCamera() {
    setCameraError('')
    const NativeDetector = (window as unknown as { BarcodeDetector?: new (options?: { formats: string[] }) => { detect: (source: HTMLVideoElement) => Promise<Array<{ rawValue: string }>> } }).BarcodeDetector
    if (!NativeDetector) { setCameraError('This browser does not provide the native QR detector. Use the manual identifier search below.'); return }
    if (!navigator.mediaDevices?.getUserMedia || !videoRef.current) { setCameraError('Camera access is unsupported; use manual search below.'); return }
    try {
      const stream = await navigator.mediaDevices.getUserMedia({ video: { facingMode: { ideal: 'environment' } }, audio: false })
      streamRef.current = stream
      videoRef.current.srcObject = stream
      await videoRef.current.play()
      const detector = new NativeDetector({ formats: ['qr_code'] })
      const scan = async () => {
        const video = videoRef.current
        if (!video || !streamRef.current) return
        try {
          const detections = await detector.detect(video)
          if (detections[0]?.rawValue) { const value = detections[0].rawValue; setCode(value.split('/r/').pop() ?? value); stopCamera(); return }
        } catch { setCameraError('The camera stream could not be scanned. You can still enter the code manually.') }
        timerRef.current = window.setTimeout(() => { void scan() }, 350)
      }
      void scan()
    } catch { setCameraError('Camera permission was denied or no camera is available. Use the manual fallback.') }
  }

  const title = kind === 'roll' ? 'Scan or find a roll' : kind === 'machine' ? 'Scan or find a machine' : 'Find a shipment manifest'
  return <section className="live-panel live-action-panel">
    <h2>{title}</h2>
    <p>Camera scanning is attempted only when browser support and permission are available. Lookup alone never records inspection, movement or dispatch.</p>
    <div className="scan-camera">
      <video ref={videoRef} muted playsInline aria-label="QR scanner camera preview" />
      <button className="button button-secondary" type="button" onClick={() => void startCamera()}>Open camera scanner</button>
      <button className="button button-quiet" type="button" onClick={stopCamera}>Stop camera</button>
    </div>
    {cameraError && <div className="live-warning" role="status">{cameraError}</div>}
    <form className="live-form" onSubmit={find}>
      <label className="live-form-wide">{kind === 'roll' ? 'Roll code or QR token' : kind === 'machine' ? 'Machine code' : 'Shipment number'}<input autoComplete="off" value={code} onChange={e => setCode(e.target.value)} placeholder={kind === 'roll' ? 'e.g. ROLL-…' : kind === 'machine' ? 'e.g. WV-02' : 'e.g. SHP-…'} required /></label>
      <div className="live-form-actions"><span>Manual fallback works when camera permission is unavailable.</span><button className="button button-primary" disabled={working}>{working ? 'Searching…' : 'Find record'}</button></div>
    </form>
    {error && <div className="live-error" role="alert">{error}</div>}
    {record && <section className="scan-result"><h3>Matched record</h3><dl>{Object.entries(record).filter(([key]) => key !== 'id' && key !== 'qr_token' && key !== 'is_demo').map(([key, value]) => <div key={key}><dt>{key.replaceAll('_', ' ')}</dt><dd>{value === null || value === '' ? '—' : typeof value === 'object' ? JSON.stringify(value) : String(value)}</dd></div>)}</dl>{kind === 'roll' && Boolean(record.qr_token) && <a className="button button-secondary" href={`/#/r/${String(record.qr_token)}`}>Open live roll passport</a>}</section>}
  </section>
}

export function StockAdjustmentRequestForm({ onSaved }: { onSaved: () => void }) {
  const client = dataService.getClient()
  const [batches, setBatches] = useState<Row[]>([])
  const [locations, setLocations] = useState<Row[]>([])
  const [batchId, setBatchId] = useState('')
  const [locationId, setLocationId] = useState('')
  const [qtyDelta, setQtyDelta] = useState('-2')
  const [reason, setReason] = useState('Physical cycle-count variance; review evidence before approval.')
  const [loading, setLoading] = useState(true)
  const [working, setWorking] = useState(false)
  const [error, setError] = useState('')
  const [notice, setNotice] = useState('')

  useEffect(() => {
    let active = true
    if (!client) { setLoading(false); setError('Supabase is not configured.'); return }
    Promise.all([
      client.from('yarn_batches').select('id,batch_code,yarn_item_id,status,unit').eq('is_demo', true).order('created_at', { ascending: false }).limit(50),
      client.from('stock_locations').select('id,code').order('code').limit(50),
    ]).then(([b, l]) => {
      if (!active) return
      if (b.error || l.error) setError(safeActionError(b.error ?? l.error))
      const batchesData = (b.data ?? []) as unknown as Row[]
      const locationsData = (l.data ?? []) as unknown as Row[]
      setBatches(batchesData); setLocations(locationsData)
      const batch = batchesData.find(row => String(row.batch_code) === 'DEMO-OPENING-COTTON-400') ?? batchesData[0]
      const location = locationsData.find(row => String(row.code) === 'RAW-01') ?? locationsData[0]
      if (batch?.id) setBatchId(String(batch.id))
      if (location?.id) setLocationId(String(location.id))
      setLoading(false)
    }).catch(e => { if (active) { setError(safeActionError(e)); setLoading(false) } })
    return () => { active = false }
  }, [client])

  async function submit(event: FormEvent) {
    event.preventDefault()
    if (!client || !batchId || !locationId || Number(qtyDelta) === 0) return
    setWorking(true); setError(''); setNotice('')
    try {
      const { data, error } = await client.rpc('rpc_request_adjustment', { p_yarn_batch_id: batchId, p_location_id: locationId, p_qty_delta: Number(qtyDelta), p_reason: reason.trim() })
      if (error) throw error
      const response = data as Row
      setNotice(`Adjustment ${String(response.adj_no ?? response.adjustment_id ?? '')} requested. No stock changed until an authorised approval.`)
      onSaved()
    } catch (e) { setError(safeActionError(e)) }
    finally { setWorking(false) }
  }

  return <section className="live-panel live-action-panel">
    <h2>Request a stock adjustment</h2>
    <p>Creates a pending request only. The ledger balance changes only after the separate role-authorised approval RPC.</p>
    {error && <div className="live-error" role="alert">{error}</div>}{notice && <div className="live-success" role="status">{notice}</div>}
    {loading ? <p className="live-empty">Loading demo batches and locations…</p> : <form className="live-form" onSubmit={submit}>
      <label>Batch<select required value={batchId} onChange={e => setBatchId(e.target.value)}>{batches.map(row => <option key={String(row.id)} value={String(row.id)}>{String(row.batch_code)} · {String(row.status)}</option>)}</select></label>
      <label>Location<select required value={locationId} onChange={e => setLocationId(e.target.value)}>{locations.map(row => <option key={String(row.id)} value={String(row.id)}>{String(row.code)}</option>)}</select></label>
      <label>Quantity change<input type="number" step="0.001" required value={qtyDelta} onChange={e => setQtyDelta(e.target.value)} /></label>
      <label className="live-form-wide">Reason<input minLength={3} required value={reason} onChange={e => setReason(e.target.value)} /></label>
      <div className="live-form-actions"><span>Request is reviewable; never a direct stock write.</span><button className="button button-primary" disabled={working || !batchId || !locationId || Number(qtyDelta) === 0}>{working ? 'Requesting…' : 'Submit for approval'}</button></div>
    </form>}
  </section>
}

export function ManifestScanPanel({ onSaved }: { onSaved: () => void }) {
  const client = dataService.getClient()
  const [shipments, setShipments] = useState<Row[]>([])
  const [shipmentId, setShipmentId] = useState('')
  const [manifest, setManifest] = useState<Row[]>([])
  const [rollCode, setRollCode] = useState('')
  const [ackMismatch, setAckMismatch] = useState(false)
  const [mismatchReason, setMismatchReason] = useState('')
  const [loading, setLoading] = useState(true)
  const [working, setWorking] = useState(false)
  const [error, setError] = useState('')
  const [notice, setNotice] = useState('')

  const loadShipments = useCallback(async () => {
    if (!client) { setLoading(false); setError('Supabase is not configured.'); return }
    const { data, error } = await client.from('shipments')
      .select('id,shipment_number,status,manifest_expected_count,manifest_scanned_count,needs_attention,order_id')
      .eq('status', 'ALLOCATED').eq('is_demo', true).order('created_at', { ascending: false }).limit(50)
    if (error) setError(safeActionError(error))
    const rows = (data ?? []) as unknown as Row[]
    setShipments(rows)
    if (!rows.some(row => String(row.id) === shipmentId)) setShipmentId(rows[0]?.id ? String(rows[0].id) : '')
    setLoading(false)
  }, [client, shipmentId])

  const loadManifest = useCallback(async () => {
    if (!client || !shipmentId) { setManifest([]); return }
    const { data, error } = await client.from('shipment_rolls')
      .select('roll_id,qty,fabric_rolls(roll_code,unit,status)')
      .eq('shipment_id', shipmentId).limit(200)
    if (error) { setError(safeActionError(error)); setManifest([]); return }
    setManifest((data ?? []) as unknown as Row[])
  }, [client, shipmentId])

  useEffect(() => { void loadShipments() }, [loadShipments])
  useEffect(() => { void loadManifest() }, [loadManifest])

  async function scan(event: FormEvent) {
    event.preventDefault()
    if (!client || !shipmentId || !rollCode.trim()) return
    setWorking(true); setError(''); setNotice('')
    try {
      const { data, error } = await client.rpc('rpc_scan_manifest', { p_shipment_id: shipmentId, p_roll_code: rollCode.trim() })
      if (error) throw error
      const result = data as Row
      const outcome = String(result.result ?? result.status ?? 'RECORDED')
      setNotice(`Manifest scan recorded: ${outcome}. Review the match counter before confirmation.`)
      setRollCode('')
      await Promise.all([loadManifest(), loadShipments()])
      onSaved()
    } catch (e) { setError(safeActionError(e)) }
    finally { setWorking(false) }
  }

  async function confirm(event: FormEvent) {
    event.preventDefault()
    if (!client || !shipmentId) return
    if (ackMismatch && mismatchReason.trim().length < 3) { setError('Enter a reason for the manifest mismatch acknowledgement.'); return }
    setWorking(true); setError(''); setNotice('')
    try {
      const { data, error } = await client.rpc('rpc_confirm_shipment', {
        p_shipment_id: shipmentId,
        p_ack_mismatch: ackMismatch,
        p_mismatch_reason: ackMismatch ? mismatchReason.trim() : null,
        p_idempotency_key: crypto.randomUUID(),
      })
      if (error) throw error
      const result = data as Row
      setNotice(`Dispatch confirmed for ${String(result.shipment_number ?? 'shipment')}. The invoice remains an internal draft.`)
      await loadShipments(); onSaved()
    } catch (e) { setError(safeActionError(e)) }
    finally { setWorking(false) }
  }

  const selected = shipments.find(row => String(row.id) === shipmentId)
  return <section className="live-panel live-action-panel">
    <h2>Scan allocated shipment</h2>
    <p>Scan each roll code individually. Duplicate, unexpected and not-on-manifest outcomes stay visible; there is no automatic bulk scan.</p>
    {error && <div className="live-error" role="alert">{error}</div>}{notice && <div className="live-success" role="status">{notice}</div>}
    {loading ? <p className="live-empty">Loading allocated shipments…</p> : shipments.length === 0 ? <div className="live-empty">No allocated shipment is waiting for a manifest scan. Create a draft and allocate eligible rolls from <a href="/#/dispatch/ready">Dispatch readiness</a>.</div> : <>
      <label className="live-inline">Allocated shipment<select value={shipmentId} onChange={e => setShipmentId(e.target.value)}>{shipments.map(row => <option key={String(row.id)} value={String(row.id)}>{String(row.shipment_number)} · {String(row.status)}</option>)}</select></label>
      <div className="live-stat-grid"><article className="live-stat"><span>Expected rolls</span><strong>{String(selected?.manifest_expected_count ?? manifest.length)}</strong></article><article className="live-stat"><span>Scanned matches</span><strong>{String(selected?.manifest_scanned_count ?? 0)}</strong></article><article className="live-stat"><span>Needs attention</span><strong>{String(selected?.needs_attention ?? false)}</strong></article></div>
      <section className="scan-result"><h3>Allocated manifest</h3>{manifest.length ? <ul>{manifest.map(row => { const roll = row.fabric_rolls as Row | null; return <li key={String(row.roll_id)}>{String(roll?.roll_code ?? row.roll_id)} · {String(row.qty)} {String(roll?.unit ?? '')} · {String(roll?.status ?? '—')}</li> })}</ul> : <p>No roll rows returned for this shipment.</p>}</section>
      <form className="live-form" onSubmit={scan}>
        <label className="live-form-wide">Roll code<input autoComplete="off" value={rollCode} onChange={e => setRollCode(e.target.value)} placeholder="Scan or enter one roll code" required /></label>
        <div className="live-form-actions"><span>One scan per submitted roll code.</span><button className="button button-secondary" disabled={working}>{working ? 'Scanning…' : 'Record scan'}</button></div>
      </form>
      <form className="live-form" onSubmit={confirm}>
        <label className="live-check"><input type="checkbox" checked={ackMismatch} onChange={e => setAckMismatch(e.target.checked)} />Acknowledge a reviewed manifest mismatch</label>
        {ackMismatch && <label className="live-form-wide">Mismatch reason<input required minLength={3} value={mismatchReason} onChange={e => setMismatchReason(e.target.value)} /></label>}
        <div className="live-form-actions"><span>Confirmation records dispatch and an internal invoice draft.</span><button className="button button-primary" disabled={working}>{working ? 'Confirming…' : 'Confirm dispatch'}</button></div>
      </form>
    </>}
  </section>
}
