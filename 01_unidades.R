#!/usr/bin/env Rscript
# ------------------------------------------------------------------------------
# 01 - Cadastro dos estabelecimentos de PE (CNES-ST)
#
# Baixa o arquivo STPEaamm.dbc do primeiro e do último mês disponível de cada
# ano do período (2023 a 2026) e guarda, para cada CNES, os dados do registro
# mais recente. Ler janeiro e dezembro de cada ano evita perder unidades que
# fecharam no meio do período (ex.: Hospital de Retaguarda em Neurologia, 2023).
#
# A natureza jurídica (NAT_JUR) é o que separa a rede complementar (prestadores
# privados e filantrópicos) dos estabelecimentos públicos, no 04_planilhas.R.
#
# Saída: dados/referencias/cnes_st_pe.csv
#   CNES, CODUFMUN, TP_UNID, TPGESTAO, NAT_JUR, ESFERA_A, CNPJ_MAN, PF_PJ,
#   COMPETENCIA_CNES (mês do arquivo de onde veio o registro)
#
# Também grava, para cada ano, o cadastro do último mês (dezembro; no ano
# corrente, o último publicado), com o vínculo SUS (VINC_SUS), em
# dados/cnes_st/st_AAAAMM.parquet: base das planilhas de estabelecimentos SUS.
#
# Só baixa de novo quando muda algum dos arquivos escolhidos.
# Uso: Rscript 01_unidades.R [--reprocessar-tudo]
# ------------------------------------------------------------------------------

source("utils.R")

UNID <- list(
  saida    = file.path(CFG$dir_dados, "referencias", "cnes_st_pe.csv"),
  controle = file.path(CFG$dir_dados, "controle", "cnes_st_processados.csv"),
  colunas  = c("CNES", "CODUFMUN", "TP_UNID", "TPGESTAO", "NAT_JUR", "ESFERA_A",
               "CNPJ_MAN", "PF_PJ"),
  dir_ano  = file.path(CFG$dir_dados, "cnes_st"),
  col_ano  = c("CNES", "CODUFMUN", "TP_UNID", "TPGESTAO", "VINC_SUS", "NAT_JUR", "ESFERA_A")
)

main <- function() {
  lst <- listar_ftp(CFG$ftp_st)
  padrao <- sprintf("^ST%s(\\d{2})(\\d{2})\\.dbc$", CFG$uf)
  lst <- lst[grepl(padrao, nome, ignore.case = TRUE)]
  lst[, mes := sub(padrao, "20\\1\\2", nome, ignore.case = TRUE)]
  lst <- lst[mes >= CFG$inicio & mes <= CFG$fim]
  if (!nrow(lst)) stop("Nenhum arquivo do CNES-ST de ", CFG$uf, " no período")
  # Primeiro e último arquivo de cada ano: o primeiro pega unidades que fecharam
  # no meio do ano e não aparecem mais no cadastro de dezembro
  lst[, ano := substr(mes, 1, 4)]
  escolhidos <- unique(lst[, .SD[c(which.min(mes), which.max(mes))], by = ano])
  assinatura <- paste(escolhidos[, paste(nome, tamanho, data, sep = "|")], collapse = ";")

  ctrl <- ler_controle(UNID$controle, "fonte")
  ultimos <- lst[, .(mes = max(mes)), by = ano]$mes
  arq_ano <- file.path(UNID$dir_ano, paste0("st_", ultimos, ".parquet"))
  if (!tem_flag("reprocessar-tudo") && file.exists(UNID$saida) && all(file.exists(arq_ano)) &&
      identical(ctrl[fonte == "CNES-ST"]$assinatura, assinatura)) {
    log_msg("CNES-ST sem mudança (%s). Nada a fazer.", paste(escolhidos$nome, collapse = ", "))
    return(invisible(NULL))
  }

  partes <- lapply(seq_len(nrow(escolhidos)), function(i) {
    e <- escolhidos[i]
    log_msg("CNES-ST: %s", e$nome)
    st <- padronizar(baixar_ler(CFG$ftp_st, e$nome), texto = c(UNID$colunas, "VINC_SUS"))
    st[, COMPETENCIA_CNES := e$mes]
    if (e$mes %chin% ultimos) {
      if (all(is.na(st$VINC_SUS))) stop("Campo VINC_SUS ausente em ", e$nome)
      x <- st[, intersect(UNID$col_ano, names(st)), with = FALSE]
      x[, TP_UNID := sprintf("%02d", as.integer(TP_UNID))]
      x[, COMPETENCIA := e$mes]
      dir.create(UNID$dir_ano, recursive = TRUE, showWarnings = FALSE)
      gravar_parquet(x, file.path(UNID$dir_ano, paste0("st_", e$mes, ".parquet")))
    }
    st[, intersect(c(UNID$colunas, "COMPETENCIA_CNES"), names(st)), with = FALSE]
  })
  # Partições de meses que deixaram de ser o último do ano (ex.: ano corrente)
  velhos <- setdiff(list.files(UNID$dir_ano, "^st_\\d{6}\\.parquet$"), basename(arq_ano))
  if (length(velhos)) file.remove(file.path(UNID$dir_ano, velhos))
  st <- rbindlist(partes, use.names = TRUE)
  st[, TP_UNID := sprintf("%02d", as.integer(TP_UNID))]
  # Registro mais recente de cada CNES
  setorder(st, CNES, -COMPETENCIA_CNES)
  st <- st[, .SD[1], by = CNES]

  gravar_csv(st, UNID$saida)
  registrar_controle(ctrl, UNID$controle, "fonte", "CNES-ST", assinatura)
  log_msg("cnes_st_pe: %d estabelecimentos", nrow(st))
}

if (sys.nframe() == 0L) main()
