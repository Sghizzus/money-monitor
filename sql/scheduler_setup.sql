-- ============================================================
-- Scheduler: tabella per la pianificazione delle esecuzioni
-- Eseguire questo script nella SQL Editor di Supabase
-- ============================================================

CREATE TABLE IF NOT EXISTS scheduler (
  id       INTEGER PRIMARY KEY DEFAULT 1,
  next_run TIMESTAMPTZ NOT NULL
);

-- Abilita RLS (accesso solo via connessione PostgreSQL diretta)
ALTER TABLE scheduler ENABLE ROW LEVEL SECURITY;

-- Inserisci il primo orario di esecuzione (subito al primo avvio)
-- Modifica il valore se vuoi posticipare il primo aggiornamento
INSERT INTO scheduler (id, next_run)
VALUES (1, now())
ON CONFLICT (id) DO NOTHING;
