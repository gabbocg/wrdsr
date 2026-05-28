#!/usr/bin/env Rscript
# ======================================================== #
#
#            WRDS Industry Financial Ratios (CIZ)
#
#                 Gabriel E. Cabrera-Guzmán
#                The University of Manchester
#
#                       Spring, 2026
#
#                https://gcabrerag.rbind.io
#
# ------------------------------ #
# email: gabriel.cabreraguzman@postgrad.manchester.ac.uk
# ======================================================== #

# Load packages
library(tidyverse)
library(DBI)
library(RPostgres)

# Create connection
# Set WRDS_USER and WRDS_PASSWORD in ~/.Renviron or as environment variables
wrds <- dbConnect(
    Postgres(),
    host = "wrds-pgdata.wharton.upenn.edu",
    dbname = "wrds",
    port = 9737,
    sslmode = "require",
    user = Sys.getenv("WRDS_USER"),
    password = Sys.getenv("WRDS_PASSWORD")
)

# ==========================================
#                 Parameters
# ------------------------------------------

# Helper functions
source("R/indratios-ciz.R")

# Year range and industry-aggregation method
BEG_YR <- 2020L
END_YR <- 2025L
AVR    <- "median"   # "mean" or "median"

# ==========================================
#               Run & Save
# ------------------------------------------

res <- indratios_ciz(wrds, BEG_YR, END_YR, avr = AVR)

if (!dir.exists("data")) dir.create("data")
saveRDS(res$firm, "data/firm_ratios.rds")
saveRDS(res$ind,  "data/ind_ratios.rds")

cat(sprintf("\nfirm_ratios.rds  %d rows  (%d firms, %d fyears)\n",
            nrow(res$firm),
            n_distinct(res$firm$gvkey),
            n_distinct(res$firm$fyear)))
cat(sprintf("ind_ratios.rds   %d rows  (%d FF49 industries, %d fyears)\n",
            nrow(res$ind),
            n_distinct(res$ind$ff49),
            n_distinct(res$ind$fyear)))

dbDisconnect(wrds)
