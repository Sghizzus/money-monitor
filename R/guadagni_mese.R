#' Identifica il periodo finanziario corrente (mese di calendario)
#'
#' Restituisce l'inizio e la fine del mese di calendario corrente.
#'
#' @param con Connessione al database (non utilizzata, mantenuta per compatibilità).
#' @return Lista con elementi \code{da} (Date, primo giorno del mese corrente) e
#'   \code{a} (Date, primo giorno del mese successivo).

periodo_attuale <- function(con) {
  da <- floor_date(today(), "month")
  a <- ceiling_date(today(), "month")

  list(da = as.Date(da), a = as.Date(a))
}

#' Calcola i guadagni nel mese di calendario corrente
#'
#' Somma tutti i movimenti positivi (entrate) dall'inizio del mese corrente a oggi,
#' come identificato da [periodo_attuale()].
#'
#' @param con Connessione al database (oggetto DBI connection).
#' @param includi_ignorati Se \code{TRUE}, include i record marcati come ignorati.
#'
#' @return Valore numerico: somma delle entrate dall'inizio del mese a oggi.
#'
#' @seealso [periodo_attuale()]

guadagni_del_mese <- function(con, includi_ignorati = FALSE) {
  periodo <- periodo_attuale(con)
  da <- periodo$da
  a <- periodo$a

  tbl(con, "movimenti") |>
    filter(
      importo > 0,
      data_valuta >= !!da,
      data_valuta < !!a,
      includi_ignorati | !ignora
    ) |>
    summarise(tot = sum(importo, na.rm = TRUE)) |>
    pull(tot)
}
