import { createClient } from "npm:@supabase/supabase-js@2";
const url = Deno.env.get("SUPABASE_URL")!;
const anonKey = Deno.env.get("SUPABASE_ANON_KEY")!;
const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const appOrigin = Deno.env.get("APP_ORIGIN") ?? "";
const svc = createClient(url, serviceKey, { auth: { persistSession: false, autoRefreshToken: false } });
function reply(body: unknown, status: number, origin = "") {
  return new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json", "Cache-Control": "no-store", ...(origin ? { "Access-Control-Allow-Origin": origin, Vary: "Origin" } : {}) } });
}
function coded(code: string, status = 400, message = "The request could not be completed.") { return reply({ code, message }, status); }
Deno.serve(async (req) => {
  const origin = req.headers.get("origin") ?? "";
  if (req.method === "OPTIONS") {
    if (!origin || origin !== appOrigin) return reply({ code: "ORIGIN_NOT_ALLOWED" }, 403);
    return new Response(null, { status: 204, headers: { "Access-Control-Allow-Origin": origin, "Access-Control-Allow-Methods": "POST, OPTIONS", "Access-Control-Allow-Headers": "authorization, apikey, content-type", "Access-Control-Max-Age": "600", Vary: "Origin" } });
  }
  if (req.method !== "POST") return reply({ code: "METHOD_NOT_ALLOWED" }, 405, origin === appOrigin ? origin : "");
  if (!appOrigin || origin !== appOrigin) return reply({ code: "ORIGIN_NOT_ALLOWED" }, 403);
  const authorization = req.headers.get("authorization") ?? "";
  const token = authorization.replace(/^Bearer\s+/i, "");
  if (!token) return reply({ code: "AUTH_REQUIRED" }, 401, origin);
  try {
    const userClient = createClient(url, anonKey, { global: { headers: { Authorization: `Bearer ${token}` } }, auth: { persistSession: false, autoRefreshToken: false } });
    const { data: authData, error: authError } = await userClient.auth.getUser(token);
    if (authError || !authData.user) return reply({ code: "AUTH_REQUIRED" }, 401, origin);
    const { data: bootstrap, error: bootstrapError } = await userClient.rpc("rpc_session_bootstrap");
    if (bootstrapError) return reply({ code: bootstrapError.message.match(/CODE: ([A-Z_]+)/)?.[1] ?? "PERMISSION_DENIED" }, 403, origin);
    if (bootstrap?.profile?.status !== "ACTIVE" || !bootstrap?.permissions?.includes("users.manage")) return reply({ code: "PERMISSION_DENIED" }, 403, origin);
    const callerId = authData.user.id;
    const body = await req.json();
    const action = String(body?.action ?? "");

    if (action === "create") {
      const email = String(body?.email ?? "").trim().toLowerCase();
      const fullName = String(body?.full_name ?? "").trim();
      const accountType = body?.account_type === "buyer" ? "buyer" : "staff";
      if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email) || fullName.length < 2 || fullName.length > 120) return reply({ code: "INVALID_INPUT" }, 400, origin);
      const password = `Etm-${crypto.randomUUID()}-${crypto.getRandomValues(new Uint32Array(1))[0].toString(16)}!`;
      const userMetadata: Record<string, unknown> = { full_name: fullName, account_type: accountType, requested_role: String(body?.requested_role ?? "") };
      let inviteCode: string | undefined;
      if (accountType === "buyer") {
        const buyerId = String(body?.buyer_id ?? "");
        if (!/^[0-9a-f-]{36}$/i.test(buyerId)) return reply({ code: "BUYER_SCOPE_REQUIRED" }, 400, origin);
        inviteCode = crypto.randomUUID().replaceAll("-", "") + crypto.randomUUID().replaceAll("-", "");
        const { error: inviteError } = await svc.from("buyer_invites").insert({ code: inviteCode, buyer_id: buyerId, expires_at: new Date(Date.now() + 7 * 86400000).toISOString(), created_by: callerId });
        if (inviteError) return reply({ code: "INVITE_CREATE_FAILED" }, 400, origin);
        userMetadata.buyer_invite_code = inviteCode;
      }
      const requireConfirm = Deno.env.get("AUTH_EMAIL_CONFIRMATION") === "true";
      const { data, error } = await svc.auth.admin.createUser({ email, password, email_confirm: !requireConfirm, user_metadata: userMetadata });
      if (error || !data.user) {
        if (inviteCode) await svc.from("buyer_invites").delete().eq("code", inviteCode);
        return reply({ code: "USER_CREATE_FAILED" }, 400, origin);
      }
      await svc.from("audit_logs").insert({ actor_user_id: callerId, action: "USER_CREATED", entity_type: "profiles", entity_id: data.user.id, after_json: { email, account_type: accountType } });
      return reply({ user_id: data.user.id, status: "PENDING_APPROVAL", one_time_password: password, buyer_invite_code: inviteCode ?? null }, 201, origin);
    }

    if (action === "approve" || action === "reject") {
      const { data, error } = await userClient.rpc("rpc_admin_decide_user", {
        p_user_id: body?.user_id, p_decision: action, p_role_keys: Array.isArray(body?.role_keys) ? body.role_keys : [],
        p_employee_id: body?.employee_id ?? null, p_buyer_id: body?.buyer_id ?? null, p_reason: body?.reason ?? null,
        p_idempotency_key: body?.idempotency_key ?? crypto.randomUUID(),
      });
      if (error) return reply({ code: error.message.match(/CODE: ([A-Z_]+)/)?.[1] ?? "ADMIN_ACTION_FAILED" }, 400, origin);
      return reply(data, 200, origin);
    }

    if (action === "set-status") {
      const { data, error } = await userClient.rpc("rpc_admin_set_user_status", { p_user_id: body?.user_id, p_status: body?.status, p_reason: body?.reason ?? null, p_idempotency_key: body?.idempotency_key ?? crypto.randomUUID() });
      if (error) return reply({ code: error.message.match(/CODE: ([A-Z_]+)/)?.[1] ?? "ADMIN_ACTION_FAILED" }, 400, origin);
      const banned = body?.status === "DISABLED" || body?.status === "REJECTED";
      await svc.auth.admin.updateUserById(String(body?.user_id), { ban_duration: banned ? "876000h" : "none" });
      return reply(data, 200, origin);
    }

    if (action === "set-roles") {
      const { data, error } = await userClient.rpc("rpc_admin_set_roles", { p_user_id: body?.user_id, p_role_keys: body?.role_keys, p_reason: body?.reason, p_idempotency_key: body?.idempotency_key ?? crypto.randomUUID() });
      if (error) return reply({ code: error.message.match(/CODE: ([A-Z_]+)/)?.[1] ?? "ADMIN_ACTION_FAILED" }, 400, origin);
      return reply(data, 200, origin);
    }

    if (action === "revoke-sessions") {
      const { error } = await svc.auth.admin.signOut(String(body?.user_id), "global");
      if (error) return reply({ code: "SESSION_REVOCATION_FAILED" }, 400, origin);
      await svc.from("audit_logs").insert({ actor_user_id: callerId, action: "SESSIONS_REVOKED", entity_type: "profiles", entity_id: body?.user_id });
      return reply({ ok: true }, 200, origin);
    }

    if (action === "reset-link") {
      const { data: profile } = await svc.from("profiles").select("email").eq("id", body?.user_id).maybeSingle();
      if (!profile?.email) return reply({ code: "NOT_FOUND" }, 404, origin);
      const redirectTo = `${appOrigin}/reset-password`;
      const { data, error } = await svc.auth.admin.generateLink({ type: "recovery", email: profile.email, options: { redirectTo } });
      if (error) return reply({ code: "RESET_LINK_FAILED" }, 400, origin);
      await svc.from("audit_logs").insert({ actor_user_id: callerId, action: "PASSWORD_RESET_LINK_CREATED", entity_type: "profiles", entity_id: body?.user_id });
      return reply({ action_link: data.properties?.action_link }, 200, origin);
    }

    return reply({ code: "UNKNOWN_ACTION" }, 400, origin);
  } catch {
    return reply({ code: "INVALID_REQUEST" }, 400, origin);
  }
});
