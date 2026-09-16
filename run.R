library(logger)
library(DBI)
library(RPostgres)

log_appender(appender_file(
  file = "logs/money-monitor.log",
  max_lines = 10000,
  max_files = 5L
))

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

tryCatch(
  {
    next_run <- dbGetQuery(
      con,
      "SELECT next_run FROM scheduler WHERE id = 1"
    )$next_run |>
      with_tz("Europe/Rome")

    now <- now() |> with_tz("Europe/Rome")

    log_info("Ora attuale:          {format(now)}")
    log_info("Prossima esecuzione:  {format(next_run)}")

    if (now >= next_run) {
      log_info("Avvio aggiornamento...")

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
          stop(e)
        }
      )
    } else {
      log_info("Troppo presto, esco.")
    }
  },
  finally = {
    dbDisconnect(con)
  }
)
