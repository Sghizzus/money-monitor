-- Aggiunge il collegamento budget_id alla tabella movimenti
-- Eseguire questo script nella SQL Editor di Supabase

ALTER TABLE movimenti
  ADD COLUMN IF NOT EXISTS budget_id INTEGER REFERENCES budgets(id) ON DELETE SET NULL;
