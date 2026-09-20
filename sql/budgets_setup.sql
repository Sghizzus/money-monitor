-- ============================================================
-- Budgets: tabella per la configurazione dei budget mensili
-- Eseguire questo script nella SQL Editor di Supabase
-- ============================================================

CREATE TABLE IF NOT EXISTS budgets (
  id             SERIAL PRIMARY KEY,
  nome           TEXT          NOT NULL,
  ordine         INTEGER       NOT NULL,   -- ordine di applicazione sequenziale
  tipo           TEXT          NOT NULL
                   CHECK (tipo IN ('fisso', 'perc_guadagni', 'perc_residuo')),
  valore         NUMERIC(10,2) NOT NULL,   -- importo in € (fisso) o percentuale (perc_*)
  accantonamento BOOLEAN       NOT NULL DEFAULT FALSE,  -- se TRUE, nessuna spesa da tracciare
  attivo         BOOLEAN       NOT NULL DEFAULT TRUE
);

-- Abilita RLS
ALTER TABLE budgets ENABLE ROW LEVEL SECURITY;
