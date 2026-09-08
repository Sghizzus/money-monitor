FROM rocker/r-ver:4.6.1

# Dipendenze di sistema in un unico layer:
# - software-properties-common: per add-apt-repository (PPA Chromium)
# - curl: richiesto da renv per i download dei pacchetti
# - libpq-dev: per RPostgres
# - libuv1: richiesto dal pacchetto R `fs`
# - chromium (via PPA xtradeb): su Ubuntu il pacchetto ufficiale è solo snap,
#   non compatibile con Docker; il PPA fornisce un .deb installabile
RUN apt-get update && apt-get install -y --no-install-recommends \
    software-properties-common \
    curl \
    libpq-dev \
    libuv1 \
    && add-apt-repository -y ppa:xtradeb/apps \
    && apt-get update \
    && apt-get install -y --no-install-recommends chromium \
    && rm -rf /var/lib/apt/lists/*

# Indica a chromote dove trovare Chrome
ENV CHROMOTE_CHROME=/usr/bin/chromium

# Crea la cartella Downloads (destinazione temporanea del file Excel)
RUN mkdir -p /root/Downloads

WORKDIR /project
RUN mkdir -p renv

# Copia l'infrastruttura renv — layer cachato finché renv.lock non cambia
COPY renv.lock renv.lock
COPY .Rprofile .Rprofile
COPY renv/activate.R renv/activate.R
COPY renv/settings.json renv/settings.json

RUN R -s -e "renv::restore()"

COPY . .

CMD ["Rscript", "run.R"]
