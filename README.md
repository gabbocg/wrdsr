# WRDS Industry Financial Ratios (CIZ)

[![R](https://img.shields.io/badge/R-%3E%3D4.1-276DC3?logo=r&logoColor=white)](https://www.r-project.org/)
[![WRDS](https://img.shields.io/badge/Data-WRDS-003366)](https://wrds-www.wharton.upenn.edu/)

An R port of the WRDS `INDRATIOS_CIZ` SAS macro. Computes 33 firm-level financial ratios from Compustat + CRSP (CIZ schema) and aggregates them at the Fama-French 49-industry level.

## Overview

This R pipeline replicates the WRDS [`indratios_ciz` macro](https://wrds-www.wharton.upenn.edu/pages/wrds-research/macros/wrds-macro-indratios-ciz/) using `dbplyr` lazy SQL against the WRDS PostgreSQL cloud. It pulls annual Compustat fundamentals, attaches monthly CRSP prices at the publication date (`datadate + 3 months end-of-month`), constructs valuation / profitability / activity / leverage / liquidity ratios, maps each firm to a Fama-French 49 industry, and emits an industry-year panel of mean or median ratios.

## Data Source

Data is pulled from WRDS (PostgreSQL). Requires a WRDS account with Compustat and CRSP access.

- `comp.funda` — Compustat annual fundamentals
- `comp.aco_pnfnda` — post-retirement benefit assets (PRBA)
- `comp.sec_mthdiv` — indicated dividend rate
- `crsp.msf_v2` — CRSP monthly security file (CIZ schema)
- `crsp.ccmxpf_lnkhist` — CRSP–Compustat link history
- `wrdsapps_finratio_ibes_ccm.firm_ratio_ibes_ccm` — used by `check.R` to validate the port against WRDS's pre-computed Financial Ratios Suite

## Methodology

The R port mirrors the SAS macro step-by-step:

1. Filter CRSP common stocks (US-incorporated, equity, `ShareType = 'NS'`).
2. Pull Compustat annual fundamentals with `indfmt = 'INDL'`, `datafmt = 'STD'`, USD reporting, US-incorporated.
3. Attach a CRSP permno via `ccmxpf_lnkhist` (`linktype ∈ {LC,LU,LS}`, `linkprim ∈ {P,C}`).
4. Join PRBA and the USD dividend rate; collect to R.
5. Attach the monthly CRSP price at `public_date = end-of-month(datadate + 3 months)`.
6. Compute firm-level ratios. Book equity follows the Davis-Fama-French construction (`seq − pref + txditc − prba`). Lag-based ratios (`roa`, `roe`, turnover ratios) are blanked when consecutive fiscal years are missing.
7. Map each firm to Fama-French 49 industry using historical Compustat SIC (`sich`); fall back to CRSP `siccd`. SIC ranges fetched from Kenneth French's data library.
8. Aggregate by `fyear × FF49` taking the requested central tendency (mean or median).

Two ratios — `bm` and `ps` — use the WRDS Financial Ratios Suite mcap conventions rather than the strict SAS macro formulas:

- `bm = bv / mcap_fye`, where `mcap_fye = prcc_f × csho` (fiscal-year-end Compustat mcap; Fama-French convention).
- `ps = mcap / sale`, where `mcap = mthprc × shrout` (contemporaneous CRSP monthly mcap).

This keeps the port aligned with `wrdsapps_finratio_ibes_ccm.firm_ratio_ibes_ccm` for direct cross-checking.

## Usage

Add your WRDS credentials to `~/.Renviron` (never commit this file):

```
WRDS_USER=your_username
WRDS_PASSWORD=your_password
```

Then set the year range in `load.R` and run:

```r
source("load.R")
```

```r
# Parameters to configure
BEG_YR <- 2020L
END_YR <- 2025L
AVR    <- "median"        # "mean" or "median"
```

This sources `R/indratios-ciz.R` and writes two files: `data/firm_ratios.rds` (firm-fyear panel) and `data/ind_ratios.rds` (FF49 industry-fyear panel).

To validate the port against the WRDS Financial Ratios Suite, run:

```r
source("check.R")
```

`check.R` reports (A) output shape, (B) industry-panel ratio magnitudes, and (C) an AAPL cross-check against [`firm_ratio_ibes_ccm`](https://wrds-www.wharton.upenn.edu/pages/grid-items/financial-ratios-firm-level/) on the eight ratios whose definitions overlap between the CIZ macro and the WRDS Suite.

## Processing Pipeline

| Step | Description |
|------|-------------|
| 1 | Pull CRSP common-stock monthly file (`crsp.msf_v2`) |
| 2 | Pull Compustat annual fundamentals (`comp.funda`); attach CCM link (`ccmxpf_lnkhist`) |
| 3 | Pull post-retirement benefit assets (`comp.aco_pnfnda`) |
| 4 | Pull USD dividend rate (`comp.sec_mthdiv`); aggregate by `(gvkey, datadate)` |
| 5 | Collect the Compustat side, derive `public_date = datadate + 3 months end-of-month` |
| 6 | Attach CRSP market data on `(permno, year-month)` |
| 7 | Compute 33 firm-level ratios with within-firm lags for average-of-two-periods inputs |
| 8 | Aggregate by `(fyear, ff49)` using the chosen central tendency |

## Output Columns

`res$firm` is a firm-fyear panel:

| Column | Description |
|--------|-------------|
| `gvkey`, `permno` | Compustat / CRSP identifiers |
| `datadate`, `fyear` | Fiscal-year-end date and fiscal year |
| `sich`, `siccd` | Historical Compustat / CRSP SIC codes |
| `ff49`, `ff49_abbr`, `ff49_desc` | Fama-French 49 industry classification |
| `eps_exi`, `eps_inci`, `mcap`, `ep`, `pe`, `ps`, `bm`, `dvy`, `dpr` | Valuation ratios |
| `gpm`, `opmad`, `ptpm`, `npm`, `cfm`, `roe`, `roa`, `ros` | Profitability ratios |
| `rect_turn`, `pay_turn`, `inv_turn`, `nwc_turn`, `at_turn`, `cash_turn` | Activity ratios |
| `der`, `der1`, `der2`, `der3`, `intcov`, `rds` | Leverage ratios |
| `curr_ratio`, `quick_ratio`, `cashr`, `invtonwc` | Liquidity ratios |

`res$ind` has the same ratio columns aggregated by `(fyear, ff49)`.

## Dependencies

```r
install.packages(c("tidyverse", "DBI", "RPostgres", "dbplyr"))
```

## References

- Wharton Research Data Services. (2024). [*WRDS Macro: Industry Financial Ratios (CIZ)*](https://wrds-www.wharton.upenn.edu/pages/wrds-research/macros/wrds-macro-indratios-ciz/).

- Wharton Research Data Services. (2016). [*WRDS Industry Financial Ratio Manual*](https://wrds-www.wharton.upenn.edu/pages/grid-items/financial-ratios-firm-level/).

- Fama, E. F., & French, K. R. (1997). [Industry costs of equity](https://doi.org/10.1016/S0304-405X(96)00896-3). *Journal of Financial Economics*, 43(2), 153–193.
