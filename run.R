library(logger)

source("R/db_connect.R")
source("R/otp_polling.R")
source("R/scarica_excel.R")
source("R/aggiorna_db.R")

con <- db_connect()

# Leggo il prossimo orario pianificato dal db
next_run <- dbGetQuery(con, "SELECT next_run FROM scheduler WHERE id = 1")$next_run
now <- Sys.time()

log_info("Ora attuale:          {format(now)}")
log_info("Prossima esecuzione:  {format(next_run)}")

if (now < next_run) {
  log_info("Troppo presto, esco.")
  poolClose(con)
  quit(save = "no", status = 0)
}

log_info("Avvio aggiornamento...")

scarica_excel(con)
aggiorna_db()

# Aggiorno il prossimo orario: aggiungo ore casuali con distribuzione
# esponenziale di parametro 1/4 (media attesa: 4 ore)
delay_hours <- rexp(1, rate = 1 / 4)
new_next_run <- next_run + delay_hours * 3600

dbExecute(
  con,
  "UPDATE scheduler SET next_run = $1 WHERE id = 1",
  params = list(new_next_run)
)

log_info("Completato. Prossima esecuzione: {format(new_next_run)}")

poolClose(con)
