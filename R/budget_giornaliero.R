#' Calcola il budget giornaliero consigliato per oggi
#'
#' Distribuisce il budget delle spese correnti (guadagni meno tutti i budget
#' configurati) sui giorni del mese con un sistema di pesi, ricalibrandosi
#' giorno per giorno sulle spese effettive **non assegnate a nessun budget**.
#'
#' @param con Connessione al database (oggetto DBI/pool).
#'
#' @return Un valore numerico non negativo (€) che rappresenta il budget
#'   giornaliero consigliato per oggi. Restituisce \code{0} se le spese
#'   non assegnate hanno già esaurito il margine disponibile.
#'
#' @seealso [calcola_budgets()], [guadagni_del_mese()]

budget_giornaliero <- function(con) {
  guadagni    <- guadagni_del_mese(con)
  budgets_df  <- tbl(con, "budgets") |> filter(attivo) |> collect()
  calc        <- calcola_budgets(guadagni, budgets_df)
  budget      <- if (nrow(calc) == 0) guadagni else last(calc$residuo_dopo)

  giorni_nel_mese <- days_in_month(today())

  # Solo spese non assegnate ad alcun budget
  spese <- tbl(con, "movimenti") |>
    filter(
      month(data_valuta) == month(today()),
      data_valuta < today(),
      importo < 0,
      !ignora,
      is.na(budget_id)
    ) |>
    mutate(giorno = day(data_valuta)) |>
    group_by(giorno) |>
    summarise(importo = sum(-importo, na.rm = TRUE)) |>
    collect()

  if (nrow(spese) > 0) {
    spese <- complete(spese, giorno = seq_len(max(giorno)), fill = list(importo = 0))
  }

  giorno <- spese$giorno
  x      <- spese$importo

  weights <- c(3, 4, rep(5, giorni_nel_mese - 4), 4, 3)
  b       <- pmax(weights * budget / giorni_nel_mese, 0)

  for (i in seq_along(giorno)) {
    b[(i + 1):giorni_nel_mese] <- pmax(
      weights[(i + 1):giorni_nel_mese] *
        (budget - sum(x[1:i])) /
        (giorni_nel_mese + 1 - i),
      0
    )
  }

  i       <- day(today())
  local_b <- b[(i + 2):pmax(i - 2, 1)]
  values  <- c(0, x[(i - 1):pmax(i - 4, 1)])
  values  <- c(values, rep(last(values), length(local_b) - length(values)))

  pmax(min(local_b - values, na.rm = TRUE), 0)
}
