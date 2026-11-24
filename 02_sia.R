#!/usr/bin/env Rscript
# ------------------------------------------------------------------------------
# 02 - Produção ambulatorial (SIA-PA) de PE, por movimento
#
# Lê os arquivos PAPEaamm[a,b,...].dbc do FTP do DATASUS, de 01/2023 em diante,
# e mantém só as linhas que interessam às planilhas:
#   - estabelecimentos da lista validada da SES (rede própria, OSS e referências),
#     qualquer que seja o gestor; e
#   - toda a produção sob gestão estadual (PA_GESTAO = 260000), onde estão os
#     prestadores da rede complementar.
# A separação por tipo de rede é feita depois, no 04_planilhas.R.
#
# Saída: uma partição por movimento em dados/sia/ e a base consolidada
#   dados/saida/sia_unidades.parquet, agregada por
#   PA_MVM (movimento = mês de processamento), PA_CMP (competência de
#   atendimento), CNES, PA_GESTAO, PA_PROC_ID e CBO (o CBO só é mantido nos
#   procedimentos 0301, consultas e atendimentos; nos demais fica vazio).
# Medidas: QTD_APRESENTADA (PA_QTDPRO), QTD_APROVADA (PA_QTDAPR),
#   VALOR_APRESENTADO (PA_VALPRO), VALOR_APROVADO (PA_VALAPR), N_REGISTROS.
#
# Só baixa movimentos novos ou republicados. Cada execução processa no máximo
# SIA$max_por_execucao movimentos (os mais recentes primeiro), para caber no
# tempo do GitHub Actions; a carga histórica se completa em execuções seguidas.
# Uso: Rscript 02_sia.R [--reprocessar-tudo] [--forcar=AAAAMM] [--max=N]
# ------------------------------------------------------------------------------

source("utils.R")

SIA <- list(
  max_por_execucao = as.integer(argumento("max") %||% "25"),
  dir      = file.path(CFG$dir_dados, "sia"),
  saida    = file.path(CFG$dir_dados, "saida", "sia_unidades.parquet"),
  controle = file.path(CFG$dir_dados, "controle", "sia_processados.csv"),
  texto    = c("PA_CODUNI", "PA_GESTAO", "PA_CMP", "PA_MVM", "PA_PROC_ID", "PA_CBOCOD"),
  numero   = c("PA_QTDPRO", "PA_QTDAPR", "PA_VALPRO", "PA_VALAPR")
)

listar_sia <- function() {
  lst <- listar_ftp(CFG$ftp_sia)
  padrao <- sprintf("^PA%s(\\d{2})(\\d{2})([a-z]?)\\.dbc$", CFG$uf)
  lst <- lst[grepl(padrao, nome, ignore.case = TRUE)]
  lst[, mvm := sub(padrao, "20\\1\\2", nome, ignore.case = TRUE)]
  lst <- lst[mvm >= CFG$inicio & mvm <= CFG$fim]
  setorder(lst, mvm, nome)
  lst[, assinatura := paste(nome, tamanho, data, sep = "|")]
  lst
}

# Lê uma parte do movimento, filtra e agrega logo em seguida, para não manter o
# arquivo inteiro (milhões de linhas) na memória.
ler_parte <- function(nome, mvm, cnes_validos) {
  dt <- padronizar(baixar_ler(CFG$ftp_sia, nome), texto = SIA$texto, numero = SIA$numero)
  n <- nrow(dt)
  dt[is.na(PA_MVM) | PA_MVM == "", PA_MVM := mvm]
  dt <- dt[PA_CODUNI %chin% cnes_validos | PA_GESTAO == CFG$gestor_estadual]
  dt[!startsWith(PA_PROC_ID, "0301") | is.na(PA_CBOCOD), PA_CBOCOD := ""]
  out <- dt[, .(QTD_APRESENTADA = sum(PA_QTDPRO, na.rm = TRUE),
                QTD_APROVADA = sum(PA_QTDAPR, na.rm = TRUE),
                VALOR_APRESENTADO = sum(PA_VALPRO, na.rm = TRUE),
                VALOR_APROVADO = sum(PA_VALAPR, na.rm = TRUE),
                N_REGISTROS = .N),
            by = .(PA_MVM, PA_CMP, CNES = PA_CODUNI, PA_GESTAO, PA_PROC_ID, CBO = PA_CBOCOD)]
  log_msg("  %s: %s registros no arquivo; %s mantidos; %d linhas agregadas",
          nome, format(n, big.mark = "."), format(nrow(dt), big.mark = "."), nrow(out))
  rm(dt); gc(verbose = FALSE)
  out
}

main <- function() {
  dir.create(SIA$dir, recursive = TRUE, showWarnings = FALSE)
  cnes_validos <- ler_validados()$CNES

  ftp <- listar_sia()
  movs <- ftp[, .(assinatura = paste(assinatura, collapse = ";")), by = mvm]
  ctrl <- ler_controle(SIA$controle, "mvm")
  forcar <- argumento("forcar")
  pend <- if (tem_flag("reprocessar-tudo")) movs else
    movs[!ctrl, on = .(mvm, assinatura)]
  if (!is.null(forcar)) pend <- unique(rbind(pend, movs[mvm == forcar]))
  # Mais recentes primeiro: o mês novo entra logo; o histórico vem nas execuções seguintes.
  setorder(pend, -mvm)
  log_msg("SIA: %d movimentos no FTP entre %s e %s; %d pendentes; processando até %d",
          nrow(movs), CFG$inicio, CFG$fim, nrow(pend), SIA$max_por_execucao)
  pend <- head(pend, SIA$max_por_execucao)

  falhas <- character()
  for (m in pend$mvm) {
    log_msg("Movimento %s", m)
    ok <- tryCatch({
      partes <- lapply(ftp[mvm == m]$nome, ler_parte, mvm = m, cnes_validos = cnes_validos)
      dt <- rbindlist(partes)
      dt <- dt[, lapply(.SD, sum), by = .(PA_MVM, PA_CMP, CNES, PA_GESTAO, PA_PROC_ID, CBO),
               .SDcols = c("QTD_APRESENTADA", "QTD_APROVADA", "VALOR_APRESENTADO", "VALOR_APROVADO", "N_REGISTROS")]
      gravar_parquet(dt, file.path(SIA$dir, sprintf("sia_%s.parquet", m)))
      ctrl <- registrar_controle(ctrl, SIA$controle, "mvm", m, pend[mvm == m]$assinatura)
      TRUE
    }, error = function(e) { log_msg("ERRO no movimento %s: %s", m, conditionMessage(e)); FALSE })
    if (!ok) falhas <- c(falhas, m)
  }

  consolidar(SIA$dir, SIA$saida)
  if (length(falhas)) {
    log_msg("Movimentos com falha (tentados de novo na próxima execução): %s", paste(falhas, collapse = ", "))
    quit(status = 1)
  }
}

if (sys.nframe() == 0L) main()
