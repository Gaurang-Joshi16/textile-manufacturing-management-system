import { createClient, type SupabaseClient } from '@supabase/supabase-js'

const url = import.meta.env.VITE_SUPABASE_URL as string | undefined
const anonKey = import.meta.env.VITE_SUPABASE_ANON_KEY as string | undefined

let client: SupabaseClient | null = null
if (url && anonKey) {
  client = createClient(url, anonKey)
}

export const dataService = {
  isConfigured: Boolean(client),
  connectionLabel: client ? 'Supabase connection available' : 'Supabase connection not configured',
  getClient: () => client,
  async list<T>(table: string, limit = 50): Promise<T[]> {
    if (!client) return []
    const { data, error } = await client.from(table).select('*').limit(limit)
    if (error) throw error
    return (data ?? []) as T[]
  },
  async write(): Promise<never> {
    throw new Error('Business writes belong to a server RPC and are not enabled in this frontend shell.')
  },
}
