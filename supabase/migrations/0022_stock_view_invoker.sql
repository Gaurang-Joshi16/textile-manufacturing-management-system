-- Secure the inventory aggregate view for the live UI.
-- SECURITY INVOKER applies each caller's underlying table grants and RLS policies.
ALTER VIEW public.v_yarn_stock SET (security_invoker = true);
REVOKE ALL ON public.v_yarn_stock FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.v_yarn_stock TO authenticated;
