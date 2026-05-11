#' Calcola il budget mensile disponibile
#'
#' Calcola il budget disponibile per il mese corrente sottraendo una
#' percentuale dai guadagni del mese (ad esempio per risparmi).
#'
#' @param con Connessione al database (oggetto DBI connection).
#' @param perc Percentuale da sottrarre ai guadagni (valore tra 0 e 1).
#'   Ad esempio, `1/9` sottrae circa l'11% per il risparmio.
#' @param includi_ignorati Se `TRUE`, include anche i record marcati come ignorati.
#'   Default `FALSE`.
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
budget_mensile <- function(con, perc, includi_ignorati = FALSE) {
  guadagni_del_mese(con, includi_ignorati) * (1 - perc)
}
