import { createClient } from "npm:@supabase/supabase-js@2";

const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
const anonKey = Deno.env.get("SUPABASE_ANON_KEY")!;
const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const appOrigin = Deno.env.get("APP_ORIGIN") ?? "";
const svc = createClient(supabaseUrl, serviceKey, { auth: { persistSession: false, autoRefreshToken: false } });
const anon = createClient(supabaseUrl, anonKey, { auth: { persistSession: false, autoRefreshToken: false } });

function response(body: unknown, status: number, origin = "") {
  return new Response(JSON.stringify(body), { status, headers: {
    "Content-Type": "application/json", "Cache-Control": "no-store",
    ...(origin ? { "Access-Control-Allow-Origin": origin, "Vary": "Origin" } : {}),
  }});
}
Deno.serve(async (req) => {
  const origin = req.headers.get("origin") ?? "";
  if (req.method === "OPTIONS") {
    if (!origin || origin !== appOrigin) return response({ code: "ORIGIN_NOT_ALLOWED" }, 403);
    return new Response(null, { status: 204, headers: {
      "Access-Control-Allow-Origin": origin, "Access-Control-Allow-Methods": "POST, OPTIONS",
      "Access-Control-Allow-Headers": "authorization, apikey, content-type", "Access-Control-Max-Age": "600", "Vary": "Origin",
    }});
  }
  if (req.method !== "POST") return response({ code: "METHOD_NOT_ALLOWED" }, 405, origin === appOrigin ? origin : "");
  if (!appOrigin || origin !== appOrigin) return response({ code: "ORIGIN_NOT_ALLOWED" }, 403);
  try {
    const body = await req.json();
    const email = typeof body?.email === "string" ? body.email.trim().toLowerCase() : "";
    const password = typeof body?.password === "string" ? body.password : "";
    if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email) || password.length < 1 || password.length > 1024) {
      return response({ code: "INVALID_CREDENTIALS", message: "Email or password is incorrect." }, 400, origin);
    }
    const forwarded = req.headers.get("x-forwarded-for")?.split(",")[0]?.trim();
    const ip = req.headers.get("cf-connecting-ip") ?? forwarded ?? "unknown";
    const since = new Date(Date.now() - 15 * 60 * 1000).toISOString();
    const [pairCheck, emailCheck] = await Promise.all([
      svc.from("login_attempts").select("id", { count: "exact", head: true }).eq("email", email).eq("ip", ip).eq("success", false).gte("created_at", since),
      svc.from("login_attempts").select("id", { count: "exact", head: true }).eq("email", email).eq("success", false).gte("created_at", since),
    ]);
    if (pairCheck.error || emailCheck.error) return response({ code: "LOGIN_UNAVAILABLE", message: "Sign-in is temporarily unavailable." }, 503, origin);
    if ((pairCheck.count ?? 0) >= 5 || (emailCheck.count ?? 0) >= 5) {
      await svc.from("login_attempts").insert({ email, ip, success: false, reason: "LOCKED_OUT" });
      await svc.from("audit_logs").insert({ action: "LOGIN_LOCKOUT", entity_type: "auth", reason: "Five failed attempts in fifteen minutes" });
      return response({ code: "LOGIN_LOCKED", message: "Email or password is incorrect. Try again later." }, 429, origin);
    }

    const { data, error } = await anon.auth.signInWithPassword({ email, password });
    if (error || !data.user || !data.session) {
      await svc.from("login_attempts").insert({ email, ip, success: false, reason: "INVALID_CREDENTIALS" });
      return response({ code: "INVALID_CREDENTIALS", message: "Email or password is incorrect." }, 401, origin);
    }
    const { data: profile, error: profileError } = await svc.from("profiles")
      .select("status,full_name,mfa_required").eq("id", data.user.id).maybeSingle();
    if (profileError || !profile) {
      await svc.from("login_attempts").insert({ email, ip, success: false, reason: "PROFILE_UNAVAILABLE" });
      return response({ code: "LOGIN_UNAVAILABLE", message: "Sign-in is temporarily unavailable." }, 503, origin);
    }
    if (profile.status !== "ACTIVE") {
      const code = profile.status === "PENDING_APPROVAL" ? "PENDING_APPROVAL" : profile.status === "REJECTED" ? "ACCOUNT_REJECTED" : "ACCOUNT_DISABLED";
      const message = profile.status === "PENDING_APPROVAL" ? "Your account is awaiting approval." : "This account cannot sign in. Contact your administrator.";
      await svc.from("login_attempts").insert({ email, ip, success: false, reason: code });
      return response({ code, message }, 403, origin);
    }
    await svc.from("login_attempts").insert({ email, ip, success: true, reason: "SIGNED_IN" });
    await svc.from("profiles").update({ last_login_at: new Date().toISOString() }).eq("id", data.user.id);
    await svc.from("audit_logs").insert({ actor_user_id: data.user.id, action: "LOGIN", entity_type: "auth", entity_id: data.user.id });
    return response({ session: data.session, user: { id: data.user.id, email: data.user.email, full_name: profile.full_name, mfa_required: profile.mfa_required } }, 200, origin);
  } catch {
    return response({ code: "INVALID_REQUEST", message: "Check the sign-in details and try again." }, 400, origin === appOrigin ? origin : "");
  }
});
