library(tidyverse)
library(readxl)
library(janitor)
library(lubridate)
library(log4r)

#' Aggiorna il database con i nuovi movimenti bancari
#'
#' Legge un file Excel contenente le transazioni bancarie dalla directory
#' corrente, identifica i nuovi record non ancora presenti nel database
#' e li inserisce nella tabella `movimenti`.
#'
#' @details La funzione:
#' \enumerate{
#'   \item Cerca un file `.xlsx` nella directory corrente
#'   \item Importa e pulisce i dati (conversione date, rinomina colonne)
#'   \item Si connette al database tramite [db_connect()]
#'   \item Confronta i dati con quelli esistenti per evitare duplicati
#'   \item Inserisce solo i nuovi record
#'   \item Rimuove il file Excel dopo l'importazione
#' }
#'
#' Il file Excel deve avere le prime 3 righe di intestazione (vengono saltate)
#' e contenere le colonne standard dell'estratto conto.
#'
#' @return Invisibilmente, `TRUE` se l'operazione è completata con successo.
#'
#' @examples
#' \dontrun{
#' # Posizionarsi nella directory contenente il file Excel
#' setwd("path/to/download")
#' aggiorna_db()
#' }
#'
#' @seealso [db_connect()] per la connessione al database

aggiorna_db <- function(log = logger()) {
  file <- list.files(pattern = "\\.xlsx$")

  if (length(file) == 0) {
    warn(log, "Nessun file .xlsx trovato nella directory corrente")
    return(invisible(FALSE))
  }

  if (length(file) > 1) {
    warn(log, str_glue("Trovati {length(file)} file. Uso il primo: {file[1]}"))
    file <- file[1]
  }

  info(log, str_glue("Individuato file {file}"))

  data <- read_excel(file, skip = 3) |>
    clean_names() |>
    mutate(across(data_valuta:data, dmy)) |>
    rename(
      valuta_movimento = valuta_6,
      valuta_saldo = valuta_8
    )

  info(log, "Caricato file in memoria. Tento la connessione al db.")

  con <- db_connect()
  on.exit(dbDisconnect(con), add = TRUE) # garantisce disconnessione

  info(log, "Connessione avvenuta con successo")

  dati_attuali <- tbl(con, "movimenti") |> collect()

  dati_da_aggiungere <- data |>
    anti_join(dati_attuali, join_by(data, disponibile))

  info(log, str_glue("{nrow(dati_da_aggiungere)} nuovi record da inserire"))

  if (nrow(dati_da_aggiungere) > 0) {
    dbAppendTable(con, "movimenti", dati_da_aggiungere)
    info(log, "Caricati i nuovi dati nel db")
  }

  file.remove(file)
  info(log, "Rimosso il file di importazione. Task terminato")

  invisible(TRUE)
}
