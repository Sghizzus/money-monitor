#' Calcola il budget mensile disponibile
#'
#' Calcola il budget disponibile per il mese corrente sottraendo una
#' percentuale dai guadagni del mese (ad esempio per risparmi).
#'
#' @param con Connessione al database (oggetto DBI connection).
#' @param perc Percentuale da sottrarre ai guadagni (valore tra 0 e 1).
#'   Ad esempio, `1/9` sottrae circa l'11% per il risparmio.
#'
#' @return Un valore numerico che rappresenta il budget disponibile
#'   dopo aver sottratto la percentuale specificata.
#'
#' @examples
#' \dontrun{
#' con <- db_connect()
#' budget_mensile(con, 1/9)
#' }
#'
#' @export
budget_mensile <- function(con, perc) {
  guadagni_del_mese(con) * (1 - perc)
}
