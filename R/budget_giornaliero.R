#' Calcola il budget giornaliero consigliato per oggi
#'
#' Distribuisce il budget mensile disponibile sui giorni del mese applicando
#' un sistema di pesi (giorni centrali pesano di più, primo e ultimo meno),
#' e ricalibra la distribuzione giorno per giorno sulla base delle spese
#' effettive già registrate. Restituisce una stima conservativa di quanto
#' è sicuro spendere oggi, tenendo conto dei giorni vicini e delle uscite
#' recenti.
#'
#' @param con Connessione al database (oggetto DBI connection).
#' @param perc Percentuale da sottrarre ai guadagni prima del calcolo
#'   (valore tra 0 e 1). Viene passata direttamente a [budget_mensile()].
#'   Ad esempio, `1/9` riserva circa l'11% per il risparmio.
#'
#' @return Un valore numerico non negativo che rappresenta il budget
#'   giornaliero consigliato per la data odierna (in unità monetarie).
#'   Restituisce `0` se le spese recenti hanno già esaurito il margine
#'   disponibile.
#'
#' @details
#' La distribuzione giornaliera usa pesi `c(3, 4, rep(5, N-4), 4, 3)`,
#' dove `N` è il numero di giorni nel mese. Dopo ogni giorno con spese
#' registrate, il budget residuo viene redistribuito proporzionalmente
#' sui giorni successivi. La stima finale è il minimo tra il budget
#' dei prossimi giorni e le spese recenti, per garantire un margine
#' di sicurezza.
#'
#' @examples
#' \dontrun{
#' con <- db_connect()
#' budget_giornaliero(con, perc = 1/9)
#' }
#'
#' @seealso [budget_mensile()], [guadagni_del_mese()]
#'
#' @export
budget_giornaliero <- function(con, perc) {
  budget <- budget_mensile(con, perc)

  giorni_nel_mese <- days_in_month(today())

  spese <- tbl(con, "movimenti") |>
    filter(
      month(data_valuta) == month(today()),
      data_valuta < today(),
      importo < 0
    ) |>
    mutate(
      giorno = day(data_valuta)
    ) |>
    group_by(giorno) |>
    summarise(
      importo = sum(-importo, na.rm = TRUE)
    ) |>
    collect()

  if (nrow(spese) > 0) {
    spese <- complete(spese, giorno = seq_len(max(giorno)), fill = list(importo = 0))
  }

  giorno <- spese$giorno
  x <- spese$importo

  weights <- c(3, 4, rep(5, giorni_nel_mese - 4), 4, 3)
  b <- pmax(weights * budget / giorni_nel_mese, 0)

  for (i in seq_along(giorno)) {
    b[(i + 1):giorni_nel_mese] <- pmax(
      weights[(i + 1):giorni_nel_mese] *
        (budget - sum(x[1:i])) /
        (giorni_nel_mese + 1 - i),
      0
    )
  }

  i <- day(today())

  local_b <- b[(i + 2):pmax(i - 2, 1)]

  values <- c(0, x[(i - 1):pmax(i - 4, 1)])

  values <- c(values, rep(last(values), length(local_b) - length(values)))

  pmax(min(local_b - values, na.rm = TRUE), 0)
}
