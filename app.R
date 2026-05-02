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

ui <- page_sidebar(
  title = "Money Monitor",
  theme = bs_theme(version = 5, preset = "shiny"),
  sidebar = sidebar(
    width = 260,
    sliderInput(
      "perc",
      "Percentuale risparmio",
      min = 0,
      max = 50,
      value = round(100 / 9),
      step = 1,
      post = "%"
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

server <- function(input, output, session) {
  thematic_shiny()

  con <- db_connect()
  onStop(function() dbDisconnect(con))

  perc <- reactive(input$perc / 100)

  output$guadagni <- renderText(fmt_eur(guadagni_del_mese(con)))

  output$budget_mens <- renderText(fmt_eur(budget_mensile(con, perc())))

  output$budget_giorn <- renderText(fmt_eur(budget_giornaliero(con, perc())))

  output$grafico <- renderPlot(grafico_saldo(con))
}

shinyApp(ui, server)
