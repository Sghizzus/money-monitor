#' Calcola il budget giornaliero consigliato per oggi
#'
#' Distribuisce il budget delle spese correnti (guadagni dal giorno dello
#' stipendio meno i budget configurati) lungo una finestra di 30 giorni,
#' ricalibrandosi sulle spese effettive non assegnate ad alcun budget
#' registrate dal giorno dello stipendio a ieri.
#'
#' @param con Connessione al database (oggetto DBI/pool).
#'
#' @return Valore numerico non negativo (€): budget giornaliero consigliato.
#'   Restituisce \code{0} se le spese hanno esaurito il margine disponibile.
#'
#' @seealso [periodo_attuale()], [calcola_budgets()], [guadagni_del_mese()]

budget_giornaliero <- function(con) {
  periodo <- periodo_attuale(con)
  da      <- periodo$da
  a       <- periodo$a

  guadagni   <- guadagni_del_mese(con)
  budgets_df <- tbl(con, "budgets") |> filter(attivo) |> collect()
  calc       <- calcola_budgets(guadagni, budgets_df)
  budget     <- if (nrow(calc) == 0) guadagni else last(calc$residuo_dopo)

  giorni_periodo  <- as.integer(a - da)          # sempre 30
  giorno_corrente <- as.integer(today() - da) + 1L  # giorno 1-indexed nel periodo

  # Spese non assegnate ad alcun budget, dal giorno dello stipendio a ieri
  spese <- tbl(con, "movimenti") |>
    filter(
      data_valuta >= !!da,
      data_valuta < today(),
      importo < 0,
      !ignora,
      is.na(budget_id)
    ) |>
    select(data_valuta, importo) |>
    collect() |>
    mutate(giorno = as.integer(data_valuta - da) + 1L) |>
    group_by(giorno) |>
    summarise(importo = sum(-importo, na.rm = TRUE))

  if (nrow(spese) > 0) {
    spese <- complete(spese, giorno = seq_len(max(giorno)), fill = list(importo = 0))
  }

  giorno <- spese$giorno
  x      <- spese$importo

  weights <- c(3, 4, rep(5, giorni_periodo - 4), 4, 3)
  b       <- pmax(weights * budget / giorni_periodo, 0)

  # Ricalibra il budget residuo giorno per giorno
  for (i in seq_along(giorno)) {
    b[(i + 1):giorni_periodo] <- pmax(
      weights[(i + 1):giorni_periodo] *
        (budget - sum(x[1:i])) /
        (giorni_periodo + 1 - i),
      0
    )
  }

  # Stima conservativa: minimo tra giorni vicini meno le spese recenti
  i       <- giorno_corrente
  local_b <- b[(i + 2):pmax(i - 2, 1)]
  values  <- c(0, x[(i - 1):pmax(i - 4, 1)])
  values  <- c(values, rep(last(values), length(local_b) - length(values)))

  pmax(min(local_b - values, na.rm = TRUE), 0)
}
