library(tidyverse)
library(readxl)
library(janitor)
library(lubridate)
library(logger)

#' Aggiorna il database con i nuovi movimenti bancari
#'
#' Legge un file Excel contenente le transazioni bancarie dalla directory
#' corrente, identifica i nuovi record non ancora presenti nel database
#' e li inserisce nella tabella `movimenti`.
#'
#' @param con connessione al db
#'
#' @details La funzione:
#' \enumerate{
#'   \item Cerca un file `.xlsx` nella directory corrente
#'   \item Importa e pulisce i dati (conversione date, rinomina colonne)
#'   \item Si connette al database tramite [db_connect()]
#'   \item Confronta i dati con quelli esistenti per evitare duplicati
#'   \item Inserisce solo i nuovi record con `ignora = FALSE`
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
#'
#' con <- db_connect()
#' aggiorna_db(con)
#' }
#'
#' @seealso [db_connect()] per la connessione al database

aggiorna_db <- function(con, transactions = NULL) {
  if (!is.null(transactions)) {
    data <- parse_transactions_json(transactions)
    log_info("Ricevute {nrow(data)} transazioni via API JSON.")
  } else {
    data <- leggi_excel()
    if (is.null(data)) return(invisible(FALSE))
  }

  dati_attuali <- tbl(con, "movimenti") |> collect()

  dati_da_aggiungere <- data |>
    anti_join(dati_attuali, join_by(data, disponibile)) |>
    mutate(ignora = FALSE)

  log_info("{nrow(dati_da_aggiungere)} nuovi record da inserire")

  if (nrow(dati_da_aggiungere) > 0) {
    dbAppendTable(con, "movimenti", dati_da_aggiungere)
    log_info("Caricati i nuovi dati nel db")
  }

  invisible(TRUE)
}

# Converte la lista di transazioni restituita dall'API JSON in un dataframe
# compatibile con la tabella `movimenti`
parse_transactions_json <- function(transactions) {
  purrr::map(transactions, \(t) {
    tibble(
      data_valuta = as.Date(substr(t$valueDate, 1, 10)),
      data = as.Date(substr(t$transactionDate, 1, 10)),
      movimento = t$name %||% NA_character_,
      importo = t$amount$amount %||% NA_real_,
      disponibile = t$balance$accountingBalance$amount %||% NA_real_,
      osservazioni = NA_character_
    )
  }) |>
    purrr::list_rbind()
}

# Legge il file Excel dalla directory corrente (flusso legacy)
leggi_excel <- function() {
  file <- list.files(pattern = "\\.xlsx$")

  if (length(file) == 0) {
    log_warn("Nessun file .xlsx trovato nella directory corrente")
    return(NULL)
  }
  if (length(file) > 1) {
    log_warn("Trovati {length(file)} file. Uso il primo: {file[1]}")
    file <- file[1]
  }

  log_info("Individuato file {file}")

  data <- read_excel(file, skip = 3) |>
    clean_names() |>
    mutate(across(data_valuta:data, dmy)) |>
    rename(valuta_movimento = valuta_6, valuta_saldo = valuta_8)

  file.remove(file)
  log_info("File rimosso dopo la lettura.")
  data
}
