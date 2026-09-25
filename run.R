library(logger)
library(DBI)
library(RPostgres)

# Un file di log per giorno, retention 30 giorni
log_appender(appender_file(
  file = paste0("logs/money-monitor-", format(Sys.Date(), "%Y-%m-%d"), ".log")
))
old_logs <- list.files("logs", pattern = "\\.log$", full.names = TRUE)
old_logs <- old_logs[file.mtime(old_logs) < Sys.time() - 30 * 86400]
if (length(old_logs) > 0) {
  file.remove(old_logs)
}

`%||%` <- function(a, b) if (is.null(a)) b else a

source("R/otp_polling.R")
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
          py_output <- system2(
            "python",
            "scarica_excel.py",
            stdout = TRUE,
            stderr = TRUE,
            wait = TRUE
          )
          log_info("Output Python:\n{paste(py_output, collapse = '\n')}")
          exit_code <- attr(py_output, "status") %||% 0L
          if (!is.null(exit_code) && exit_code != 0) {
            stop("scarica_excel.py fallito (exit code: ", exit_code, ")")
          }
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
