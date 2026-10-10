import { createContext, useCallback, useContext, useEffect, useMemo, useState, type FormEvent, type ReactNode } from 'react'
import type { Session } from '@supabase/supabase-js'
import { AlertCircle, CheckCircle2, Clock3, Factory, ShieldCheck } from 'lucide-react'
import { dataService } from './services/data'
import './Auth.css'

export type SessionProfile = {
  id: string; email: string; full_name: string; phone: string | null; status: 'PENDING_APPROVAL' | 'ACTIVE' | 'DISABLED' | 'REJECTED';
  employee_id: string | null; buyer_id: string | null; mfa_required: boolean; last_login_at: string | null;
}
export type SessionBootstrap = { profile: SessionProfile; roles: string[]; permissions: string[]; settings: Record<string, unknown> }
type AuthResult = { ok: boolean; code?: string; message?: string }
type AuthContextValue = { loading: boolean; session: Session | null; bootstrap: SessionBootstrap | null; idleWarning: boolean; signIn: (email: string, password: string) => Promise<AuthResult>; signUp: (form: SignUpForm) => Promise<AuthResult>; signOut: (global?: boolean) => Promise<void>; continueSession: () => void }
type SignUpForm = { fullName: string; email: string; phone: string; password: string; accountType: 'staff' | 'buyer'; requestedRole: string; buyerInviteCode: string }
const AuthContext = createContext<AuthContextValue | null>(null)
const site = import.meta.env.VITE_SUPABASE_URL as string | undefined
const anonKey = import.meta.env.VITE_SUPABASE_ANON_KEY as string | undefined

function getMessage(payload: unknown, fallback: string) {
  if (payload && typeof payload === 'object' && 'message' in payload && typeof (payload as { message?: unknown }).message === 'string') return (payload as { message: string }).message
  return fallback
}

export function AuthProvider({ children }: { children: ReactNode }) {
  const client = dataService.getClient()
  const [loading, setLoading] = useState(true)
  const [session, setSession] = useState<Session | null>(null)
  const [bootstrap, setBootstrap] = useState<SessionBootstrap | null>(null)
  const [idleWarning, setIdleWarning] = useState(false)

  const loadBootstrap = useCallback(async (next: Session | null) => {
    if (!client || !next) { setBootstrap(null); return null }
    const { data, error } = await client.rpc('rpc_session_bootstrap')
    if (error) {
      setBootstrap(null)
      if (error.message.includes('USER_NOT_ACTIVE')) await client.auth.signOut({ scope: 'local' })
      return null
    }
    const result = data as SessionBootstrap
    setBootstrap(result)
    return result
  }, [client])

  useEffect(() => {
    if (!client) { setLoading(false); return }
    let alive = true
    client.auth.getSession().then(async ({ data }) => {
      if (!alive) return
      setSession(data.session)
      if (data.session) await loadBootstrap(data.session)
      if (alive) setLoading(false)
    }).catch(() => { if (alive) setLoading(false) })
    const { data: listener } = client.auth.onAuthStateChange((_event, next) => {
      if (!alive) return
      setSession(next)
      if (!next) { setBootstrap(null); return }
      window.setTimeout(() => { if (alive) void loadBootstrap(next) }, 0)
    })
    return () => { alive = false; listener.subscription.unsubscribe() }
  }, [client, loadBootstrap])

  const signIn = useCallback(async (email: string, password: string): Promise<AuthResult> => {
    if (!site || !anonKey || !client) return { ok: false, code: 'NOT_CONFIGURED', message: 'The sign-in service is not configured.' }
    try {
      const { data, error } = await client.auth.signInWithPassword({ email, password })
      if (error) return { ok: false, code: error.name, message: error.message }
      if (!data.session) return { ok: false, code: 'SESSION_MISSING', message: 'Sign-in succeeded but no session was returned.' }
      await loadBootstrap(data.session)
      return { ok: true }
    } catch {
      return { ok: false, code: 'NETWORK_ERROR', message: 'Unable to reach the sign-in service. Check your connection and retry.' }
    }
  }, [client, loadBootstrap])

  const signUp = useCallback(async (form: SignUpForm): Promise<AuthResult> => {
    if (!client) return { ok: false, code: 'NOT_CONFIGURED', message: 'The sign-up service is not configured.' }
    if (form.password.length < 12) return { ok: false, code: 'PASSWORD_TOO_SHORT', message: 'Use at least 12 characters for your password.' }
    if (/password|123456|qwerty/i.test(form.password)) return { ok: false, code: 'PASSWORD_TOO_COMMON', message: 'Choose a less common password pattern.' }
    if (form.accountType === 'buyer') {
      const { error } = await client.rpc('rpc_validate_buyer_invite', { p_code: form.buyerInviteCode.trim() })
      if (error) return { ok: false, code: 'INVALID_BUYER_INVITE', message: 'That buyer invite code is invalid, expired or already used.' }
    }
    const { data, error } = await client.auth.signUp({ email: form.email.trim().toLowerCase(), password: form.password, options: { data: {
      full_name: form.fullName.trim(), phone: form.phone.trim() || null, account_type: form.accountType,
      requested_role: form.accountType === 'staff' ? form.requestedRole : null,
      buyer_invite_code: form.accountType === 'buyer' ? form.buyerInviteCode.trim() : null,
    } } })
    if (error) return { ok: false, code: 'SIGNUP_FAILED', message: error.message }
    if (data.session) { setSession(data.session); await loadBootstrap(data.session) }
    return { ok: true, message: data.session ? 'Account created. It is awaiting administrator approval.' : 'Check your email to confirm your account, then return to sign in.' }
  }, [client, loadBootstrap])

  const signOut = useCallback(async (global = false) => {
    if (!client) return
    sessionStorage.setItem('everest-return-route', window.location.hash || '#/login')
    try { await client.rpc('rpc_log_logout') } catch { /* Best effort: auth revocation takes precedence. */ }
    await client.auth.signOut({ scope: global ? 'global' : 'local' })
    client.removeAllChannels()
    setBootstrap(null); setSession(null); setIdleWarning(false)
  }, [client])

  const continueSession = useCallback(() => setIdleWarning(false), [])
  useEffect(() => {
    if (!session || !bootstrap || bootstrap.profile.status !== 'ACTIVE') return
    const privileged = bootstrap.permissions.some((p) => ['users.manage', 'finance.read', 'compensation.read', 'payroll.approve'].includes(p))
    const raw = bootstrap.settings[privileged ? 'idle_timeout_privileged_min' : 'idle_timeout_shop_floor_min']
    const idleMs = Math.max(2, Number(raw) || (privileged ? 30 : 480)) * 60_000
    let warningTimer = 0
    let expiryTimer = 0
    const clear = () => { window.clearTimeout(warningTimer); window.clearTimeout(expiryTimer) }
    const reset = () => { clear(); setIdleWarning(false); warningTimer = window.setTimeout(() => { setIdleWarning(true); expiryTimer = window.setTimeout(() => void signOut(false), 60_000) }, Math.max(1000, idleMs - 60_000)) }
    const events: (keyof WindowEventMap)[] = ['pointerdown', 'keydown', 'touchstart', 'scroll']
    events.forEach((event) => window.addEventListener(event, reset, { passive: true }))
    reset()
    return () => { clear(); events.forEach((event) => window.removeEventListener(event, reset)) }
  }, [session, bootstrap, signOut])

  const value = useMemo(() => ({ loading, session, bootstrap, idleWarning, signIn, signUp, signOut, continueSession }), [loading, session, bootstrap, idleWarning, signIn, signUp, signOut, continueSession])
  return <AuthContext.Provider value={value}>{children}</AuthContext.Provider>
}
export function useAuth() {
  const value = useContext(AuthContext)
  if (!value) throw new Error('useAuth must be used within AuthProvider')
  return value
}

export function AuthGate({ children }: { children: ReactNode }) {
  const { loading, session, bootstrap, idleWarning, signOut, continueSession } = useAuth()
  if (loading) return <div className="auth-screen"><div className="auth-card"><div className="auth-mark"><Factory /></div><p>Checking your secure session…</p></div></div>
  if (!dataService.isConfigured) return <div className="auth-screen"><div className="auth-card"><div className="auth-mark"><AlertCircle /></div><h1>Supabase is not configured</h1><p>Set the public Supabase URL and anon key in the frontend environment to continue.</p></div></div>
  if (!session) return <AuthScreen />
  if (!bootstrap) return <div className="auth-screen"><div className="auth-card"><div className="auth-mark"><ShieldCheck /></div><h1>Access unavailable</h1><p>Your session could not be verified. Sign in again or contact an administrator.</p><button className="auth-button" onClick={() => void signOut(false)}>Return to sign in</button></div></div>
  if (bootstrap.profile.status === 'PENDING_APPROVAL') return <div className="auth-screen"><div className="auth-card"><div className="auth-mark"><Clock3 /></div><span className="auth-kicker">Account review</span><h1>Awaiting approval</h1><p>Your sign-up is recorded. A system administrator must approve your account before operational data is available.</p><button className="auth-button auth-button-outline" onClick={() => void signOut(false)}>Sign out</button></div></div>
  if (bootstrap.profile.status !== 'ACTIVE') return <div className="auth-screen"><div className="auth-card"><div className="auth-mark"><AlertCircle /></div><h1>Account unavailable</h1><p>This account is disabled or rejected. Contact your administrator.</p><button className="auth-button auth-button-outline" onClick={() => void signOut(false)}>Sign out</button></div></div>
  return <>{children}{idleWarning && <div className="idle-backdrop" role="alertdialog" aria-modal="true" aria-label="Session expiring soon"><div className="idle-card"><Clock3 size={24} /><h2>Still there?</h2><p>Your session will sign out in 60 seconds due to inactivity. Continue to keep working.</p><button className="auth-button" onClick={continueSession}>Continue session</button><button className="auth-link" onClick={() => void signOut(false)}>Sign out now</button></div></div>}</>
}

const DEMO_ACCOUNTS = [
  { label: 'System administrator', alias: 'admin.demo', email: 'admin@everest-demo.test', password: '74p9JmRCn9zxhZT_s2fkU3cZEDIi96mHk1M0Pi8S-KgAa1!' },
  { label: 'Factory manager', alias: 'manager.demo', email: 'manager@everest-demo.test', password: 'dVWo_5x1tRLBe4rL-M7tGZGO1AU' },
  { label: 'Production planner / supervisor', alias: 'planner.demo', email: 'supervisor@everest-demo.test', password: 'lAF0iFi0GPVJm0onfqFtLsYUXSE' },
  { label: 'Machine operator', alias: 'operator.demo', email: 'operator1@everest-demo.test', password: 'Y5qHwoIKClR4ddEqNHPubeIUwrE' },
  { label: 'Storekeeper', alias: 'store.demo', email: 'storekeeper@everest-demo.test', password: 'KK3rZp0q4GDDrXkd5Mhw9twm5GM' },
  { label: 'Quality inspector', alias: 'quality.demo', email: 'inspector@everest-demo.test', password: 'Saz-8OAWtckLlMglsUTYubosaQ0' },
  { label: 'Dispatch officer', alias: 'dispatch.demo', email: 'dispatch@everest-demo.test', password: 'gWUSnXeUABRETkASGqB1umWZCR0' },
  { label: 'HR / payroll officer', alias: 'hr.demo', email: 'hr@everest-demo.test', password: 'XILt8z02zDcmnbizrOmu3C4lsMg' },
  { label: 'Finance officer', alias: 'finance.demo', email: 'finance@everest-demo.test', password: 'bXCw19Vvr4fKtFqkUqjrLrlzmXg' },
  { label: 'Buyer / customer', alias: 'buyer.demo', email: 'buyer.lotus@everest-demo.test', password: 'jjx_6BVGnBBbVton3v5J08i3b8Q' }
];

function AuthScreen() {
  const { signIn, signUp } = useAuth()
  const [mode, setMode] = useState<'login' | 'signup' | 'forgot'>('login')
  const [busy, setBusy] = useState(false)
  const [notice, setNotice] = useState('')
  const [error, setError] = useState('')
  const [form, setForm] = useState<SignUpForm>({ fullName: '', email: '', phone: '', password: '', accountType: 'staff', requestedRole: '', buyerInviteCode: '' })
  const [loginEmail, setLoginEmail] = useState('')
  const [loginPassword, setLoginPassword] = useState('')
  const client = dataService.getClient()
  const change = (key: keyof SignUpForm, value: string) => setForm((v) => ({ ...v, [key]: value }))
  const submitLogin = async (event: FormEvent) => {
    event.preventDefault(); setError(''); setNotice(''); setBusy(true)
    const result = await signIn(loginEmail, loginPassword); setBusy(false)
    if (!result.ok) setError(result.message ?? 'Sign-in failed.')
    else { const target = sessionStorage.getItem('everest-return-route'); if (target) { window.location.hash = target.replace(/^#/, '') ; sessionStorage.removeItem('everest-return-route') } }
  }
  const submitSignup = async (event: FormEvent) => {
    event.preventDefault(); setError(''); setNotice(''); setBusy(true)
    const result = await signUp(form); setBusy(false)
    if (!result.ok) setError(result.message ?? 'Sign-up failed.')
    else setNotice(result.message ?? 'Your account was created.')
  }
  const submitForgot = async (event: FormEvent) => {
    event.preventDefault(); setError(''); setNotice(''); setBusy(true)
    if (!client) { setBusy(false); setError('Supabase is not configured.'); return }
    const { error: resetError } = await client.auth.resetPasswordForEmail(loginEmail.trim().toLowerCase(), { redirectTo: `${window.location.origin}/#/reset-password` })
    setBusy(false)
    if (resetError) setError('Password reset could not be sent. Ask an administrator for a reset link.')
    else setNotice('If this account can receive reset email, a recovery link has been sent.')
  }
  return <main className="auth-screen"><section className="auth-card">
    <div className="auth-brand"><div className="auth-mark"><span>ET</span></div><div><strong>Everest Textile Mills</strong><small>Integrated workshop ledger</small></div></div>
    <span className="auth-kicker">Demo preview · Operations · Traceability · Control</span>
    <h1>{mode === 'login' ? 'Sign in to your workspace' : mode === 'signup' ? 'Request workspace access' : 'Reset your password'}</h1>
    <p className="auth-lead">Workflow actions are permission-checked by Supabase; this preview uses synthetic demo records.</p>
    <p className="auth-preview-note">Test environment: seeded records are synthetic. Successful workflow actions may update this demo Supabase project.</p>
    {error && <div className="auth-alert auth-alert-error" role="alert"><AlertCircle size={17} />{error}</div>}
    {notice && <div className="auth-alert auth-alert-success" role="status"><CheckCircle2 size={17} />{notice}</div>}
    {mode === 'login' && <form onSubmit={submitLogin} className="auth-form">
      <label>Email<input autoComplete="username" type="email" required value={loginEmail} onChange={(e) => setLoginEmail(e.target.value)} /></label>
      <label>Password<input autoComplete="current-password" type="password" required value={loginPassword} onChange={(e) => setLoginPassword(e.target.value)} /></label>
      <div className="demo-roles-section">
        <div className="demo-roles-header">
          <div>
            <strong>Choose a demo role</strong>
            <p>Fills credentials only; it does not sign you in.</p>
          </div>
          <span className="demo-roles-count">10 roles</span>
        </div>
        <div className="demo-roles-grid">
          {DEMO_ACCOUNTS.map(acc => (
            <button key={acc.email} type="button" className="demo-role-button" onClick={() => { setLoginEmail(acc.email); setLoginPassword(acc.password); }}>
              <strong>{acc.label}</strong>
              <span>{acc.alias}</span>
            </button>
          ))}
        </div>
      </div>
      <button className="auth-button" disabled={busy}>{busy ? 'Signing in…' : 'Sign in'}</button>
      <button type="button" className="auth-link" onClick={() => { setMode('forgot'); setError(''); setNotice('') }}>Forgot password?</button>
    </form>}
    {mode === 'signup' && <form onSubmit={submitSignup} className="auth-form"><label>Full name<input autoComplete="name" required maxLength={120} value={form.fullName} onChange={(e) => change('fullName',e.target.value)} /></label><label>Work email<input autoComplete="email" type="email" required value={form.email} onChange={(e) => change('email',e.target.value)} /></label><label>Phone (optional)<input autoComplete="tel" value={form.phone} onChange={(e) => change('phone',e.target.value)} /></label><label>Password (12+ characters)<input autoComplete="new-password" type="password" minLength={12} required value={form.password} onChange={(e) => change('password',e.target.value)} /></label><label>Account type<select value={form.accountType} onChange={(e) => setForm((v) => ({ ...v, accountType: e.target.value as 'staff'|'buyer' }))}><option value="staff">Staff</option><option value="buyer">Buyer / customer</option></select></label>{form.accountType==='staff'&&<label>Requested role (informational)<select value={form.requestedRole} onChange={(e)=>change('requestedRole',e.target.value)}><option value="">Choose a role</option><option value="factory_manager">Factory manager</option><option value="production_supervisor">Production supervisor</option><option value="machine_operator">Machine operator</option><option value="storekeeper">Storekeeper</option><option value="quality_inspector">Quality inspector</option><option value="dispatch_officer">Dispatch officer</option><option value="hr_payroll_officer">HR and payroll officer</option><option value="finance_officer">Finance officer</option></select></label>}{form.accountType==='buyer'&&<label>Buyer invite code<input required value={form.buyerInviteCode} onChange={(e)=>change('buyerInviteCode',e.target.value)} /></label>}<button className="auth-button" disabled={busy}>{busy?'Submitting…':'Request access'}</button></form>}
    {mode === 'forgot' && <form onSubmit={submitForgot} className="auth-form"><label>Email<input autoComplete="email" type="email" required value={loginEmail} onChange={(e)=>setLoginEmail(e.target.value)} /></label><button className="auth-button" disabled={busy}>{busy?'Sending…':'Send reset link'}</button></form>}
    <div className="auth-switch">{mode==='login'?<>New to the workspace? <button onClick={()=>{setMode('signup');setError('');setNotice('')}}>Request access</button></>:<>Already have access? <button onClick={()=>{setMode('login');setError('');setNotice('')}}>Sign in</button></>}</div>
    <div className="auth-foot"><ShieldCheck size={15} /> Access approval and data visibility are enforced by Supabase Row Level Security.</div>
  </section></main>
}
