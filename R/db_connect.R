library(DBI)
library(RPostgres)

#' Connessione al database PostgreSQL su Supabase
#'
#' Stabilisce una connessione al database PostgreSQL ospitato su Supabase
#' utilizzando le credenziali configurate.
#'
#' @details La password viene letta dalla variabile d'ambiente `DB_PWD`.
#'   Assicurarsi che sia impostata prima di chiamare la funzione.
#'
#' @return Un oggetto di connessione `PqConnection` da utilizzare con le
#'   funzioni DBI.
#'
#' @examples
#' \dontrun{
#' con <- db_connect()
#' dbListTables(con)
#' dbDisconnect(con)
#' }

db_connect <- function() {
  dbConnect(
    RPostgres::Postgres(),
    dbname = "postgres",
    host = "aws-1-eu-west-3.pooler.supabase.com",
    port = 5432,
    user = "postgres.pntkrsospmzbuyelbmac",
    password = Sys.getenv("DB_PWD")
  )
}
