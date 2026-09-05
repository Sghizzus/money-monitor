-- ============================================================
-- OTP Relay: tabella e policies per il relay OTP via Tasker
-- Eseguire questo script nella SQL Editor di Supabase
-- ============================================================

-- 0. Abilita RLS sulla tabella movimenti
--    La connessione PostgreSQL diretta (RPostgres) bypassa RLS,
--    quindi l'app e lo scraper continuano a funzionare normalmente.
--    Senza policies per anon, la tabella diventa inaccessibile via REST API.
ALTER TABLE movimenti ENABLE ROW LEVEL SECURITY;


-- 1. Tabella otp_relay
CREATE TABLE IF NOT EXISTS otp_relay (
  id         UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  otp_code   TEXT NOT NULL,
  created_at TIMESTAMPTZ DEFAULT now()
);

-- 2. Abilita Row Level Security
ALTER TABLE otp_relay ENABLE ROW LEVEL SECURITY;

-- 3. Policy: anon può solo INSERT (Tasker invia l'OTP)
--    Non può SELECT, UPDATE o DELETE → non può leggere i codici
CREATE POLICY "tasker_insert_only"
  ON otp_relay
  FOR INSERT
  TO anon
  WITH CHECK (true);

-- 4. Nessuna policy SELECT/UPDATE/DELETE per anon
--    → con RLS abilitato, anon non può leggere né modificare nulla

-- 5. Il service_role (usato dallo scraper via connessione diretta
--    PostgreSQL) bypassa RLS automaticamente

-- 6. Pulizia automatica: rimuove i record più vecchi di 5 minuti
--    Eseguire come pg_cron job (Supabase Dashboard > Database > Extensions > pg_cron)
--    Oppure eseguirlo manualmente/dallo scraper dopo ogni uso
--
--    SELECT cron.schedule(
--      'cleanup_otp_relay',
--      '*/5 * * * *',
--      $$DELETE FROM otp_relay WHERE created_at < now() - interval '5 minutes'$$
--    );
