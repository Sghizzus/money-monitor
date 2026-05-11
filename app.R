library(shiny)
library(bslib)
library(bsicons)
library(tidyverse)
library(DBI)
library(RPostgres)
library(scales)
library(thematic)
library(lubridate)
library(tidyr)
library(DT)

source("R/db_connect.R")
source("R/guadagni_mese.R")
source("R/budget_mensile.R")
source("R/budget_giornaliero.R")
source("R/grafico_saldo.R")

fmt_eur <- label_currency(
  prefix = "\u20ac ",
  big.mark = ".",
  decimal.mark = ",",
  accuracy = 0.01
)

mesi_italiani <- c(
  "1" = "Gennaio", "2" = "Febbraio",  "3" = "Marzo",
  "4" = "Aprile",  "5" = "Maggio",    "6" = "Giugno",
  "7" = "Luglio",  "8" = "Agosto",    "9" = "Settembre",
  "10" = "Ottobre","11" = "Novembre", "12" = "Dicembre"
)

# --- UI ---

dashboard_ui <- layout_sidebar(
  sidebar = sidebar(
    width = 260,
    sliderInput(
      "perc",
      "Percentuale risparmio",
      min = 0, max = 50, value = round(100 / 9),
      step = 1, post = "%"
    )
  ),
  layout_column_wrap(
    width = 1 / 3,
    fill = FALSE,
    value_box(
      title = "Guadagni del mese",
      value = textOutput("guadagni"),
      theme = "success",
      showcase = bs_icon("graph-up-arrow")
    ),
    value_box(
      title = "Budget mensile",
      value = textOutput("budget_mens"),
      theme = "primary",
      showcase = bs_icon("wallet2")
    ),
    value_box(
      title = "Budget giornaliero",
      value = textOutput("budget_giorn"),
      theme = "info",
      showcase = bs_icon("calendar-day")
    )
  ),
  card(
    full_screen = TRUE,
    card_header("Andamento saldo"),
    plotOutput("grafico", height = "400px")
  )
)

movimenti_ui <- layout_sidebar(
  sidebar = sidebar(
    width = 200,
    selectInput("anno", "Anno", choices = NULL),
    selectInput("mese", "Mese", choices = NULL)
  ),
  card(
    full_screen = TRUE,
    card_header("Movimenti"),
    DTOutput("tbl_movimenti")
  )
)

ui <- page_navbar(
  title = "Money Monitor",
  theme = bs_theme(version = 5, preset = "shiny"),
  nav_panel("Dashboard", dashboard_ui),
  nav_panel("Movimenti", movimenti_ui)
)

# --- Server ---

server <- function(input, output, session) {
  thematic_shiny()

  con <- db_connect()
  onStop(function() dbDisconnect(con))

  perc <- reactive(input$perc / 100)

  # Trigger per aggiornare il dashboard dopo ogni modifica a "ignora"
  refresh <- reactiveVal(0)

  # ---- Dashboard ----

  output$guadagni <- renderText({
    refresh()
    fmt_eur(guadagni_del_mese(con))
  })

  output$budget_mens <- renderText({
    refresh()
    fmt_eur(budget_mensile(con, perc()))
  })

  output$budget_giorn <- renderText({
    refresh()
    fmt_eur(budget_giornaliero(con, perc()))
  })

  output$grafico <- renderPlot({
    refresh()
    grafico_saldo(con)
  })

  # ---- Tabella movimenti ----

  movimenti_data <- reactiveVal()

  observe({
    df <- tbl(con, "movimenti") |>
      arrange(desc(data_valuta), desc(id)) |>
      collect()
    movimenti_data(df)
  })

  # Aggiorna le scelte di anno al caricamento dei dati
  observe({
    df <- movimenti_data()
    req(df)

    anni <- sort(unique(year(df$data_valuta)), decreasing = TRUE)
    updateSelectInput(session, "anno", choices = anni, selected = year(today()))
  })

  # Aggiorna le scelte di mese quando cambia l'anno
  observe({
    df <- movimenti_data()
    req(df, input$anno)

    mesi_disp <- df |>
      filter(year(data_valuta) == as.integer(input$anno)) |>
      pull(data_valuta) |>
      month() |>
      unique() |>
      sort(decreasing = TRUE)

    scelte <- setNames(mesi_disp, mesi_italiani[as.character(mesi_disp)])
    sel <- if (as.integer(input$anno) == year(today())) month(today()) else max(mesi_disp)
    updateSelectInput(session, "mese", choices = scelte, selected = sel)
  })

  output$tbl_movimenti <- renderDT({
    df <- movimenti_data()
    req(df, input$anno, input$mese)

    df |>
      filter(
        year(data_valuta) == as.integer(input$anno),
        month(data_valuta) == as.integer(input$mese)
      ) |>
      mutate(
        ignora = sprintf(
          '<input type="checkbox" class="ignora-cb" data-id="%d" %s>',
          id, ifelse(ignora, "checked", "")
        )
      ) |>
      select(data_valuta, data, movimento, importo, disponibile, osservazioni, ignora) |>
      datatable(
        escape = FALSE,
        selection = "none",
        rownames = FALSE,
        options = list(pageLength = 25),
        callback = JS("
          table.on('change', '.ignora-cb', function() {
            var id = parseInt($(this).data('id'));
            var checked = $(this).is(':checked');
            Shiny.setInputValue('toggle_ignora', {id: id, valore: checked}, {priority: 'event'});
          });
        ")
      ) |>
      formatCurrency(
        columns = c("importo", "disponibile"),
        currency = "\u20ac ",
        before = TRUE,
        digits = 2,
        mark = ".",
        dec.mark = ","
      )
  })

  observeEvent(input$toggle_ignora, {
    info <- input$toggle_ignora

    dbExecute(
      con,
      "UPDATE movimenti SET ignora = $1 WHERE id = $2",
      list(info$valore, info$id)
    )

    refresh(refresh() + 1)
  })
}

shinyApp(ui, server)
