#' Identifica il periodo finanziario corrente (finestra di 30 giorni)
#'
#' Trova la data dell'ultimo stipendio come il più grande movimento positivo
#' negli ultimi 45 giorni. Da quella data costruisce una finestra di 30 giorni
#' che rappresenta il "mese finanziario" corrente.
#'
#' @param con Connessione al database.
#' @return Lista con elementi \code{da} (Date, inizio periodo) e
#'   \code{a} (Date, fine periodo = da + 30 giorni).

periodo_attuale <- function(con) {
  cutoff <- today() - days(32)

  da <- tbl(con, "movimenti") |>
    filter(importo > 0, !ignora, data_valuta >= !!cutoff) |>
    select(data_valuta, importo) |>
    collect() |>
    slice_max(importo, n = 1, with_ties = FALSE) |>
    pull(data_valuta)

  if (length(da) == 0 || is.na(da)) {
    da <- floor_date(today(), "month")
  }

  list(da = as.Date(da), a = as.Date(da) + days(30))
}

#' Calcola i guadagni nel periodo finanziario corrente
#'
#' Somma tutti i movimenti positivi (entrate) a partire dalla data dell'ultimo
#' stipendio, identificata da [periodo_attuale()].
#'
#' @param con Connessione al database (oggetto DBI connection).
#' @param includi_ignorati Se \code{TRUE}, include i record marcati come ignorati.
#'
#' @return Valore numerico: somma delle entrate dal giorno dello stipendio a oggi.
#'
#' @seealso [periodo_attuale()]

guadagni_del_mese <- function(con, includi_ignorati = FALSE) {
  da <- periodo_attuale(con)$da

  tbl(con, "movimenti") |>
    filter(
      importo > 0,
      data_valuta >= !!da,
      includi_ignorati | !ignora
    ) |>
    summarise(tot = sum(importo, na.rm = TRUE)) |>
    pull(tot)
}
