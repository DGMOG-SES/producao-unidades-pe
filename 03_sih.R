#!/usr/bin/env Rscript
# ------------------------------------------------------------------------------
# 03 - Produção hospitalar (SIH, AIH reduzida - RD) de PE, por mês de arquivo
#
# Lê os arquivos RDPEaamm.dbc do FTP do DATASUS, de 01/2019 em diante, e
# guarda TODAS as AIH de PE, agregadas. A seleção é feita no 04_planilhas.R.
#
# Saída: uma partição por mês em dados/sih/ e a base consolidada
#   dados/saida/sih_unidades.parquet, agregada por
#   COMPETENCIA (ANO_CMPT + MES_CMPT, mês de processamento da AIH), CNES,
#   GESTOR (UF_ZI), PROC_REA (procedimento realizado), ESPEC (especialidade
#   do leito), CAR_INT (caráter: 01 eletivo, 02 urgência...), COMPLEX
#   (02 média, 03 alta complexidade), IDENT (1 = AIH normal, 5 = longa permanência),
#   NAT_JUR (natureza jurídica), MUNIC_MOV (município do estabelecimento) e
#   FINANC (tipo de financiamento) e TP_GESTAO (campo GESTAO da AIH: 2/E
#   estadual, 1/M municipal; é a "Gestao" do RD_PE.DEF usado no TabWin da SES).
# Medidas: N_AIH, DIARIAS (QT_DIARIAS), OBITOS (MORTE = 1),
#   VALOR_TOTAL (VAL_TOT), VALOR_SH (serviços hospitalares), VALOR_SP (serviços profissionais).
#
# Só baixa meses novos ou republicados.
# Uso: Rscript 03_sih.R [--reprocessar-tudo] [--forcar=AAAAMM] [--max=N] [--minutos=N]
# ------------------------------------------------------------------------------

source("utils.R")

SIH <- list(
  max_por_execucao = as.integer(argumento("max") %||% "60"),
  dir      = file.path(CFG$dir_dados, "sih"),
  saida    = file.path(CFG$dir_dados, "saida", "sih_unidades.parquet"),
  # v2: layout com GESTAO; meses do layout anterior são refeitos
  controle = file.path(CFG$dir_dados, "controle", "sih_processados_v2.csv"),
  texto    = c("ANO_CMPT", "MES_CMPT", "CNES", "UF_ZI", "PROC_REA", "ESPEC", "CAR_INT",
               "COMPLEX", "IDENT", "MORTE", "NAT_JUR", "MUNIC_MOV", "FINANC", "GESTAO"),
  numero   = c("QT_DIARIAS", "VAL_TOT", "VAL_SH", "VAL_SP")
)

listar_sih <- function() {
  lst <- listar_ftp(CFG$ftp_sih)
  padrao <- sprintf("^RD%s(\\d{2})(\\d{2})\\.dbc$", CFG$uf)
  lst <- lst[grepl(padrao, nome, ignore.case = TRUE)]
  lst[, mes := sub(padrao, "20\\1\\2", nome, ignore.case = TRUE)]
  lst <- lst[mes >= CFG$inicio & mes <= CFG$fim]
  lst[, assinatura := paste(nome, tamanho, data, sep = "|")]
  setorder(lst, mes)
  lst
}

processar_rd <- function(nome) {
  rd <- padronizar(baixar_ler(CFG$ftp_sih, nome), texto = SIH$texto, numero = SIH$numero)
  n <- nrow(rd)
  n_estadual <- sum(rd$UF_ZI == CFG$gestor_estadual, na.rm = TRUE)
  if (n_estadual == 0) log_msg("  AVISO: nenhuma AIH com UF_ZI = %s em %s; confira o código do gestor",
                               CFG$gestor_estadual, nome)
  out <- rd[, .(N_AIH = .N,
                DIARIAS = sum(QT_DIARIAS, na.rm = TRUE),
                OBITOS = sum(MORTE == "1", na.rm = TRUE),
                VALOR_TOTAL = sum(VAL_TOT, na.rm = TRUE),
                VALOR_SH = sum(VAL_SH, na.rm = TRUE),
                VALOR_SP = sum(VAL_SP, na.rm = TRUE)),
            by = .(COMPETENCIA = paste0(ANO_CMPT, MES_CMPT), CNES, GESTOR = UF_ZI, PROC_REA,
                   ESPEC, CAR_INT, COMPLEX, IDENT, NAT_JUR, MUNIC_MOV, FINANC, TP_GESTAO = GESTAO)]
  log_msg("  %s: %s AIH no arquivo (%s sob gestão estadual); %d linhas agregadas",
          nome, format(n, big.mark = "."), format(n_estadual, big.mark = "."), nrow(out))
  out
}

main <- function() {
  dir.create(SIH$dir, recursive = TRUE, showWarnings = FALSE)

  ftp <- listar_sih()
  ctrl <- ler_controle(SIH$controle, "mes")
  forcar <- argumento("forcar")
  pend <- if (tem_flag("reprocessar-tudo")) ftp else ftp[!ctrl, on = .(mes, assinatura)]
  if (!is.null(forcar)) pend <- unique(rbind(pend, ftp[mes == forcar]))
  setorder(pend, -mes)
  log_msg("SIH: %d arquivos no FTP entre %s e %s; %d pendentes; processando até %d",
          nrow(ftp), CFG$inicio, CFG$fim, nrow(pend), SIH$max_por_execucao)
  pend <- head(pend, SIH$max_por_execucao)

  falhas <- character()
  inicio <- Sys.time()
  for (i in seq_len(nrow(pend))) {
    if (tempo_esgotado(inicio, argumento("minutos"))) {
      log_msg("Limite de %s minutos atingido; os meses restantes ficam para a próxima execução", argumento("minutos"))
      break
    }
    p <- pend[i]
    ok <- tryCatch({
      dt <- processar_rd(p$nome)
      gravar_parquet(dt, file.path(SIH$dir, sprintf("rd_%s.parquet", p$mes)))
      ctrl <- registrar_controle(ctrl, SIH$controle, "mes", p$mes, p$assinatura)
      publicar_parcial(paste("SIH: mês", p$mes))
      TRUE
    }, error = function(e) { log_msg("ERRO em %s: %s", p$nome, conditionMessage(e)); FALSE })
    if (!ok) falhas <- c(falhas, p$nome)
  }

  consolidar(SIH$dir, SIH$saida)
  if (length(falhas)) {
    log_msg("Arquivos com falha (tentados de novo na próxima execução): %s", paste(falhas, collapse = ", "))
    quit(status = 1)
  }
}

if (sys.nframe() == 0L) main()
