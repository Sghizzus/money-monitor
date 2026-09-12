library(logger)
library(DBI)
library(RPostgres)

source("R/otp_polling.R")
source("R/scarica_excel.R")
source("R/aggiorna_db.R")

con <- dbConnect(
  Postgres(),
  dbname = "postgres",
  host = "aws-1-eu-west-3.pooler.supabase.com",
  port = 5432,
  user = "postgres.pntkrsospmzbuyelbmac",
  password = Sys.getenv("DB_PWD")
)

# Leggo il prossimo orario pianificato dal db
next_run <- tbl(con, "scheduler") |>
  pull(next_run) |>
  with_tz("Europe/Rome")

now <- now()

log_info("Ora attuale:          {format(now)}")
log_info("Prossima esecuzione:  {format(next_run)}")

if (now < next_run) {
  log_info("Troppo presto, esco.")
  dbDisconnect(con)
  quit(save = "no", status = 0)
}

log_info("Avvio aggiornamento...")

# Aggiorno next_run subito, prima di tentare lo scraping.
# Così anche in caso di errore (es. banca che blocca il login)
# il container non ritenta ogni 15 minuti ma rispetta il delay casuale.
delay_hours <- rexp(1, rate = 1 / sqrt(24))
new_next_run <- next_run + dhours(delay_hours)
dbExecute(
  con,
  "UPDATE scheduler SET next_run = $1 WHERE id = 1",
  params = list(new_next_run)
)
log_info("Prossima esecuzione pianificata: {format(new_next_run)}")

tryCatch(
  {
    scarica_excel(con)
    aggiorna_db(con)
    log_info("Aggiornamento completato con successo.")
  },
  error = function(e) {
    log_error("Aggiornamento fallito: {conditionMessage(e)}")
  }
)

dbDisconnect(con)
