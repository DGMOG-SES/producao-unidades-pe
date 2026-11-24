#!/usr/bin/env Rscript
# ------------------------------------------------------------------------------
# 01 - Cadastro dos estabelecimentos de PE (CNES-ST)
#
# Baixa o arquivo STPEaamm.dbc do último mês disponível de cada ano do período
# (2023, 2024, 2025 e 2026) e guarda, para cada CNES, os dados do registro mais
# recente. Usar mais de um ano evita perder unidades que fecharam no meio do
# período e ainda têm produção em 2023-2025.
#
# A natureza jurídica (NAT_JUR) é o que separa a rede complementar (prestadores
# privados e filantrópicos) dos estabelecimentos públicos, no 04_planilhas.R.
#
# Saída: dados/referencias/cnes_st_pe.csv
#   CNES, CODUFMUN, TP_UNID, TPGESTAO, NAT_JUR, ESFERA_A, CNPJ_MAN, PF_PJ,
#   COMPETENCIA_CNES (mês do arquivo de onde veio o registro)
#
# Só baixa de novo quando muda algum dos arquivos escolhidos.
# Uso: Rscript 01_unidades.R [--reprocessar-tudo]
# ------------------------------------------------------------------------------

source("utils.R")

UNID <- list(
  saida    = file.path(CFG$dir_dados, "referencias", "cnes_st_pe.csv"),
  controle = file.path(CFG$dir_dados, "controle", "cnes_st_processados.csv"),
  colunas  = c("CNES", "CODUFMUN", "TP_UNID", "TPGESTAO", "NAT_JUR", "ESFERA_A",
               "CNPJ_MAN", "PF_PJ")
)

main <- function() {
  lst <- listar_ftp(CFG$ftp_st)
  padrao <- sprintf("^ST%s(\\d{2})(\\d{2})\\.dbc$", CFG$uf)
  lst <- lst[grepl(padrao, nome, ignore.case = TRUE)]
  lst[, mes := sub(padrao, "20\\1\\2", nome, ignore.case = TRUE)]
  lst <- lst[mes >= CFG$inicio & mes <= CFG$fim]
  if (!nrow(lst)) stop("Nenhum arquivo do CNES-ST de ", CFG$uf, " no período")
  # Último arquivo de cada ano
  lst[, ano := substr(mes, 1, 4)]
  escolhidos <- lst[, .SD[which.max(mes)], by = ano]
  assinatura <- paste(escolhidos[, paste(nome, tamanho, data, sep = "|")], collapse = ";")

  ctrl <- ler_controle(UNID$controle, "fonte")
  if (!tem_flag("reprocessar-tudo") && file.exists(UNID$saida) &&
      identical(ctrl[fonte == "CNES-ST"]$assinatura, assinatura)) {
    log_msg("CNES-ST sem mudança (%s). Nada a fazer.", paste(escolhidos$nome, collapse = ", "))
    return(invisible(NULL))
  }

  partes <- lapply(seq_len(nrow(escolhidos)), function(i) {
    e <- escolhidos[i]
    log_msg("CNES-ST: %s", e$nome)
    st <- padronizar(baixar_ler(CFG$ftp_st, e$nome), texto = UNID$colunas)
    st[, COMPETENCIA_CNES := e$mes]
    st
  })
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
