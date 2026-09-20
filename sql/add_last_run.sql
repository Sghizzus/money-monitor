-- Aggiunge la colonna last_run alla tabella scheduler
-- Eseguire questo script nella SQL Editor di Supabase

ALTER TABLE scheduler ADD COLUMN IF NOT EXISTS last_run TIMESTAMPTZ;
