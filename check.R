#!/usr/bin/env Rscript
# ======================================================== #
#
#       Validate indratios_ciz vs WRDS Financial Ratios
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
library(dbplyr)
library(lubridate)

# Load the dataset produced by load.R
stopifnot(file.exists("data/firm_ratios.rds"),
          file.exists("data/ind_ratios.rds"))

firm <- readRDS("data/firm_ratios.rds")
ind  <- readRDS("data/ind_ratios.rds")

BEG_YR <- min(firm$fyear, na.rm = TRUE)
END_YR <- max(firm$fyear, na.rm = TRUE)

# ==========================================
#         (A) Output-shape check
# ------------------------------------------

cat("\n== (A) Output shape ==\n")
cat(sprintf("  firm-level rows  : %d\n", nrow(firm)))
cat(sprintf("  unique firms     : %d\n", n_distinct(firm$gvkey)))
cat(sprintf("  fyear coverage   : %d–%d\n", BEG_YR, END_YR))
cat(sprintf("  industry-yr rows : %d\n", nrow(ind)))
cat(sprintf("  FF49 industries  : %d\n", n_distinct(ind$ff49)))

# ==========================================
#    (B) Industry-panel magnitude check
# ------------------------------------------

ratio_cols <- setdiff(names(ind), c("fyear", "ff49", "ff49_abbr", "ff49_desc"))

mag <- tibble(
    ratio  = ratio_cols,
    median = vapply(ratio_cols, \(r) stats::median(ind[[r]], na.rm = TRUE), numeric(1)),
    p10    = vapply(ratio_cols, \(r) stats::quantile(ind[[r]], 0.10, na.rm = TRUE, names = FALSE), numeric(1)),
    p90    = vapply(ratio_cols, \(r) stats::quantile(ind[[r]], 0.90, na.rm = TRUE, names = FALSE), numeric(1)),
    n_ind  = vapply(ratio_cols, \(r) sum(!is.na(ind[[r]])), integer(1))
)

cat("\n== (B) Industry-panel magnitudes ==\n")
print(mag, n = Inf)

# ==========================================
#      (C) AAPL overlap vs WRDS Suite
# ------------------------------------------

wrds <- dbConnect(
    Postgres(),
    host = "wrds-pgdata.wharton.upenn.edu",
    dbname = "wrds",
    port = 9737,
    sslmode = "require",
    user = Sys.getenv("WRDS_USER"),
    password = Sys.getenv("WRDS_PASSWORD")
)

overlap_ratios <- c("bm", "gpm", "ptpm", "npm", "cfm",
                    "curr_ratio", "quick_ratio", "ps")

mine_aapl <- firm |>
    filter(permno == 14593L, fyear >= BEG_YR, fyear <= END_YR) |>
    select(permno, fyear, datadate, any_of(overlap_ratios)) |>
    mutate(public_date = ceiling_date(datadate %m+% months(3), "month") - days(1))

wrds_aapl <- tbl(wrds, in_schema("wrdsapps_finratio_ibes_ccm",
                                 "firm_ratio_ibes_ccm")) |>
    filter(permno      == 14593L,
           public_date %in% !!unique(mine_aapl$public_date)) |>
    select(public_date, any_of(overlap_ratios)) |>
    collect()

cat("\n== (C) AAPL overlap check (CIZ macro vs WRDS Suite) ==\n")
print(
    bind_rows(
        ciz_macro  = mine_aapl |> select(public_date, all_of(overlap_ratios)),
        wrds_suite = wrds_aapl,
        .id = "source"
    ) |>
        arrange(public_date, source),
    width = Inf
)

dbDisconnect(wrds)
