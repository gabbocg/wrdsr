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

# R port of the WRDS SAS macro `indratios_ciz`.
# https://wrds-www.wharton.upenn.edu/pages/wrds-research/macros/wrds-macro-indratios-ciz/

# Load packages
library(DBI)
library(dplyr)
library(dbplyr)
library(tidyr)
library(tibble)
library(stringr)
library(lubridate)
    
# ==========================================
#                  Helpers
# ------------------------------------------

# SAS `sum()` semantics: NA only when all arguments are missing.
sas_sum <- function(...) {
    
    m <- do.call(cbind, lapply(list(...), as.numeric))
    out <- rowSums(m, na.rm = TRUE)
    out[rowSums(!is.na(m)) == 0] <- NA_real_
    
    out
    
}

# Fetch and parse Kenneth French's Siccodes49.txt.
fetch_ff49 <- function(url = "https://mba.tuck.dartmouth.edu/pages/faculty/ken.french/ftp/Siccodes49.zip") {
    
    tf <- tempfile(fileext = ".zip"); td <- tempfile(); dir.create(td)
    utils::download.file(url, tf, mode = "wb", quiet = TRUE)
    utils::unzip(tf, exdir = td)
    txt <- readLines(list.files(td, pattern = "\\.txt$", full.names = TRUE)[1])

    cur_num <- NA_integer_; cur_abbr <- NA_character_; cur_desc <- NA_character_
    rows <- list()
    
    for (ln in txt) {
        
        if (!nzchar(str_trim(ln))) next
        rng <- str_match(ln, "^\\s*(\\d{4})-(\\d{4})")
        
        if (!is.na(rng[1, 1])) {
            
            rows[[length(rows) + 1L]] <- tibble(
                ff49      = cur_num,
                ff49_abbr = cur_abbr,
                ff49_desc = cur_desc,
                sic_lo    = as.integer(rng[1, 2]),
                sic_hi    = as.integer(rng[1, 3])
            )
            
        } else {
            
            hdr <- str_match(ln, "^\\s*(\\d+)\\s+(\\S+)\\s*(.*)$")
            if (!is.na(hdr[1, 1])) {
                
                cur_num  <- as.integer(hdr[1, 2])
                cur_abbr <- hdr[1, 3]
                cur_desc <- str_trim(hdr[1, 4])
                
            }
            
        }
        
    }
    
    bind_rows(rows)
    
}

# Map SIC vector to FF49 industry tags. Unmapped non-missing SICs → industry 49.
assign_ff49 <- function(sic, ff49_tbl) {
    
    expanded <- ff49_tbl |>
        rowwise() |>
        mutate(sic = list(seq(sic_lo, sic_hi))) |>
        ungroup() |>
        unnest(sic) |>
        select(sic, ff49, ff49_abbr, ff49_desc) |>
        distinct(sic, .keep_all = TRUE)

    res <- tibble(sic = as.integer(sic), .ord = seq_along(sic)) |>
        left_join(expanded, by = "sic") |>
        arrange(.ord) |>
        mutate(
            ff49      = if_else(!is.na(sic) & is.na(ff49), 49L, ff49),
            ff49_abbr = if_else(!is.na(ff49) & is.na(ff49_abbr), "Other", ff49_abbr),
            ff49_desc = if_else(!is.na(ff49) & is.na(ff49_desc), "Almost Nothing", ff49_desc)
        )
    
    res[, c("ff49", "ff49_abbr", "ff49_desc")]
    
}

# ==========================================
#                   Main
# ------------------------------------------

indratios_ciz <- function(conn, beg_yr, end_yr, avr = c("mean", "median"), ff49_tbl = NULL) {

    avr <- match.arg(avr)
    if (is.null(ff49_tbl)) ff49_tbl <- fetch_ff49()

    beg_yr   <- as.integer(beg_yr)
    end_yr   <- as.integer(end_yr)
    # CRSP window extends one year on each side of the funda range so edge-year
    # firms get a CRSP row to match (fyear ∈ [beg_yr-1, end_yr+1]).
    beg_date <- as.Date(sprintf("%d-01-01", beg_yr - 1L))
    end_date <- as.Date(sprintf("%d-12-31", end_yr + 1L))

    ratio_vars <- c(
        "eps_exi", "eps_inci", "mcap", "ep", "pe", "ps", "bm", "dvy", "dpr",
        "gpm", "opmad", "ptpm", "npm", "cfm", "roe", "roa", "ros",
        "rect_turn", "pay_turn", "inv_turn", "nwc_turn", "at_turn", "cash_turn",
        "der", "der1", "der2", "der3", "intcov", "rds",
        "curr_ratio", "quick_ratio", "cashr", "invtonwc"
    )

    # --- 1. CRSP common-stock monthly file ---
    message("[indratios_ciz] pulling crsp.msf_v2 ...")
    crsp_data <- tbl(conn, in_schema("crsp", "msf_v2")) |>
        filter(
            sharetype       == "NS",
            securitytype    == "EQTY",
            securitysubtype == "COM",
            usincflg        == "Y",
            issuertype %in% c("ACOR", "CORP"),
            mthcaldt >= !!beg_date,
            mthcaldt <= !!end_date
        ) |>
        select(permno, mthcaldt, mthprc, shrout, mthcumfacpr, siccd) |>
        collect()

    # --- 2. Compustat funda + ccmxpf_lnkhist ---
    message("[indratios_ciz] pulling comp.funda + crsp.ccmxpf_lnkhist ...")
    funda_vars <- c(
        "che","cshpri","csho","ajex","ibc","dpc","esubc","ib","dp","epspx",
        "sich","epspi","xint","idit","cogs","xrd","sale","oibdp","oiadp",
        "dlc","txpd","act","lct","invt","rect","ni","seq","ceq","ap","pstk",
        "at","lt","fic","pstkrv","pstkl","txditc","ibadj","dvc","dvt","tie",
        "tii","dltt","curcd","prcc_f"
    )
    # NOTE: Compustat's `pi` (pretax income) collides with PostgreSQL's pi()
    # built-in function. Unquoted, `SELECT pi` returns 3.14159 every row. The
    # `sql('"pi"')` injection below forces PG to read the column.

    funda <- tbl(conn, in_schema("comp", "funda")) |>
        filter(
            indfmt  == "INDL",
            datafmt == "STD",
            popsrc  == "D",
            consol  == "C",
            curcd   == "USD",
            fic     == "USA",
            fyear   >= beg_yr - 1L,
            fyear   <= end_yr + 1L
        ) |>
        mutate(pretax_inc = sql('"pi"')) |>
        select(gvkey, datadate, fyear, pretax_inc, all_of(funda_vars))

    link <- tbl(conn, in_schema("crsp", "ccmxpf_lnkhist")) |>
        filter(linktype %in% c("LC", "LU", "LS"),
               linkprim %in% c("P", "C")) |>
        select(gvkey, lpermno, linkdt, linkenddt)

    funda_link <- funda |>
        left_join(link, by = "gvkey") |>
        filter((is.na(linkdt)    | linkdt   <= datadate),
               (is.na(linkenddt) | datadate <= linkenddt))

    # --- 3. Post-retirement benefit assets ---
    prba <- tbl(conn, in_schema("comp", "aco_pnfnda")) |>
        filter(indfmt == "INDL", datafmt == "STD",
               popsrc == "D", consol  == "C") |>
        select(gvkey, datadate, prba)

    # --- 4. Dividend rates (USD only) ---
    dvrate <- tbl(conn, in_schema("comp", "sec_mthdiv")) |>
        filter(curcddvm == "USD") |>
        group_by(gvkey, datadate) |>
        summarise(dvrate = sum(dvrate, na.rm = TRUE), .groups = "drop")

    # --- 5. Collect Compustat side ---
    message("[indratios_ciz] collecting joined Compustat side ...")
    comp_data <- funda_link |>
        left_join(prba,   by = c("gvkey", "datadate")) |>
        left_join(dvrate, by = c("gvkey", "datadate")) |>
        collect() |>
        mutate(
            datadate    = as.Date(datadate),
            public_date = ceiling_date(datadate %m+% months(3), "month") - days(1)
        )

    # --- 6. Attach CRSP market data by (permno, year-month) ---
    crsp_ym <- crsp_data |> mutate(ym = format(mthcaldt, "%Y%m"))

    all_data <- comp_data |>
        mutate(ym = format(public_date, "%Y%m")) |>
        left_join(crsp_ym, by = c("lpermno" = "permno", "ym")) |>
        select(-ym) |>
        arrange(gvkey, datadate) |>
        distinct(gvkey, datadate, .keep_all = TRUE)

    # --- 7. Firm-level ratios ---
    message("[indratios_ciz] computing firm-level ratios ...")
    firm <- all_data |>
        arrange(gvkey, datadate) |>
        group_by(gvkey) |>
        mutate(
            gap = fyear - lag(fyear),

            se = case_when(
                !is.na(seq)                ~ seq,
                !is.na(ceq) & !is.na(pstk) ~ ceq + pstk,
                !is.na(at)  & !is.na(lt)   ~ at - lt,
                TRUE                       ~ NA_real_
            ),
            bv_raw = case_when(
                !is.na(pstkrv) ~ sas_sum(se, -pstkrv),
                !is.na(pstkl)  ~ sas_sum(se, -pstkl),
                !is.na(pstk)   ~ sas_sum(se, -pstk),
                TRUE           ~ NA_real_
            ),
            bv = sas_sum(bv_raw, txditc, -prba),
            bv = if_else(bv < 0, NA_real_, bv),

            mcap     = (mthprc * shrout) / 1000,
            adjprc   = abs(mthprc) / mthcumfacpr,
            mcap_fye = if_else(prcc_f > 0 & !is.na(csho), prcc_f * csho, NA_real_),

            eps_exi  = epspx / ajex,
            eps_inci = epspi / ajex,
            ep       = eps_exi / adjprc,
            pe       = adjprc / eps_exi,
            ps       = mcap / sale,
            bm       = if_else(!is.na(mcap_fye) & mcap_fye != 0, bv / mcap_fye, NA_real_),
            dvy      = dvrate / adjprc,
            dpr      = dvc / ibadj,

            npm   = ib / sale,
            opmad = (oibdp - dp) / sale,
            gpm   = (sale - cogs) / sale,
            ptpm  = pretax_inc / sale,
            cfm   = (ibc + dpc) / sale,
            rds   = xrd / sale,

            roa = (ni + xint) / ((at   + lag(at))   / 2),
            ros =  ni         / ((sale + lag(sale)) / 2),
            roe =  ni         / ((bv   + lag(bv))   / 2),

            nwc       = act - lct,
            inv_turn  = sale / ((invt + lag(invt)) / 2),
            at_turn   = sale / ((at   + lag(at))   / 2),
            rect_turn = sale / ((rect + lag(rect)) / 2),
            pay_turn  = sale / ((ap   + lag(ap))   / 2),
            nwc_turn  = sale / ((nwc  + lag(nwc))  / 2),
            cash_turn = sale / ((che  + lag(che))  / 2),

            der   = dltt / mcap,
            der1  = (dltt + dlc) / mcap,
            der2  = dltt / bv,
            der3  = dltt / (act - lct),

            oper_cf = oibdp - txpd - ((act - lct) - lag(act - lct)),
            intcov  = (xint - idit) / oper_cf,

            curr_ratio  = act / lct,
            quick_ratio = (act - invt) / lct,
            cashr       = che / lct,
            invtonwc    = invt / (act - lct)
        ) |>
        # SAS: blank out lag-based ratios when consecutive-year gap is missing
        mutate(across(
            c(inv_turn, at_turn, rect_turn, pay_turn, nwc_turn, cash_turn,
              roa, roe, ros, oper_cf),
            ~ if_else(is.na(gap) | gap != 1, NA_real_, .x)
        )) |>
        ungroup() |>
        mutate(
            sich  = if_else(sich  == 0, NA_real_, as.numeric(sich)),
            siccd = if_else(siccd == 0, NA_real_, as.numeric(siccd))
        )

    # FF49 mapping: prefer historical SIC from Compustat; fall back to CRSP siccd
    sic_use <- with(firm, if_else(!is.na(sich), sich, siccd))
    firm <- bind_cols(firm, assign_ff49(sic_use, ff49_tbl))

    firm_out <- firm |>
        select(
            gvkey, permno = lpermno, datadate, fyear, sich, siccd,
            ff49, ff49_abbr, ff49_desc, all_of(ratio_vars)
        )

    # --- 8. Industry aggregation ---
    message("[indratios_ciz] aggregating to FF49 industries ...")
    agg_fun <- if (avr == "mean") {
        
        function(x) mean(x, na.rm = TRUE)
        
    } else {
        
        function(x) stats::median(x, na.rm = TRUE)
        
    }

    ind_out <- firm_out |>
        filter(!is.na(ff49), fyear >= beg_yr, fyear <= end_yr) |>
        group_by(fyear, ff49, ff49_abbr, ff49_desc) |>
        summarise(across(all_of(ratio_vars), agg_fun), .groups = "drop") |>
        arrange(fyear, ff49) |>
        mutate(across(all_of(ratio_vars),
                      ~ if_else(is.nan(.x) | is.infinite(.x), NA_real_, .x)))

    list(firm = firm_out, ind = ind_out)
    
}
