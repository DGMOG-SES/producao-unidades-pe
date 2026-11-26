#!/usr/bin/env Rscript
# ------------------------------------------------------------------------------
# 02 - Produção ambulatorial (SIA-PA) de PE, por movimento
#
# Lê os arquivos PAPEaamm[a,b,...].dbc do FTP do DATASUS, de 01/2019 em diante,
# e guarda TODA a produção de PE, agregada. A seleção de unidades e a
# separação por tipo de rede são feitas depois, no 04_planilhas.R; assim uma
# regra nova não exige baixar tudo de novo.
#
# Saída: uma partição por movimento em dados/sia/ e a base consolidada
#   dados/saida/sia_unidades.parquet, agregada por
#   PA_MVM (movimento = mês de processamento), PA_CMP (competência de
#   atendimento), CNES, PA_GESTAO, PA_PROC_ID, CBO (o CBO só é mantido nos
#   procedimentos 0301, consultas e atendimentos; nos demais fica vazio),
#   PA_UFMUN (município do estabelecimento), PA_TPUPS (tipo de unidade),
#   PA_TIPPRE (tipo de prestador), PA_NAT_JUR (natureza jurídica), PA_TPFIN
#   (tipo de financiamento), PA_DOCORIG (instrumento: BPA-C, BPA-I, APAC...) e
#   PA_CONDIC (condição de gestão: D dupla, E estadual, P municipal; é a
#   "Gestao" do Prod_PE.def usado no TabWin da SES) e PA_CATEND (caráter de
#   atendimento: 01 eletivo, 02 urgência, 03-06 acidentes, 99/00 não informado).
# Medidas: QTD_APRESENTADA (PA_QTDPRO), QTD_APROVADA (PA_QTDAPR),
#   VALOR_APRESENTADO (PA_VALPRO), VALOR_APROVADO (PA_VALAPR), N_REGISTROS.
#
# Só baixa movimentos novos ou republicados. Cada execução processa no máximo
# SIA$max_por_execucao movimentos (os mais recentes primeiro), para caber no
# tempo do GitHub Actions; a carga histórica se completa em execuções seguidas.
# Uso: Rscript 02_sia.R [--reprocessar-tudo] [--forcar=AAAAMM] [--max=N] [--minutos=N]
#                       [--periodo=AAAAMM-AAAAMM]
# ------------------------------------------------------------------------------

source("utils.R")

SIA <- list(
  max_por_execucao = as.integer(argumento("max") %||% "25"),
  dir      = file.path(CFG$dir_dados, "sia"),
  saida    = file.path(CFG$dir_dados, "saida", "sia_unidades.parquet"),
  # v3: layout com PA_CONDIC e PA_CATEND; movimentos de layouts anteriores são refeitos
  controle = file.path(CFG$dir_dados, "controle", "sia_processados_v3.csv"),
  # Além das chaves, guarda campos de classificação (natureza jurídica, tipo de
  # unidade e de prestador, financiamento, instrumento de registro e município)
  # para que regras novas possam ser aplicadas sem baixar tudo de novo.
  texto    = c("PA_CODUNI", "PA_GESTAO", "PA_CMP", "PA_MVM", "PA_PROC_ID", "PA_CBOCOD",
               "PA_UFMUN", "PA_TPUPS", "PA_TIPPRE", "PA_NAT_JUR", "PA_TPFIN", "PA_DOCORIG",
               "PA_CONDIC", "PA_CATEND"),
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
ler_parte <- function(nome, mvm) {
  dt <- padronizar(baixar_ler(CFG$ftp_sia, nome), texto = SIA$texto, numero = SIA$numero)
  n <- nrow(dt)
  dt[is.na(PA_MVM) | PA_MVM == "", PA_MVM := mvm]
  dt[!startsWith(PA_PROC_ID, "0301") | is.na(PA_CBOCOD), PA_CBOCOD := ""]
  out <- dt[, .(QTD_APRESENTADA = sum(PA_QTDPRO, na.rm = TRUE),
                QTD_APROVADA = sum(PA_QTDAPR, na.rm = TRUE),
                VALOR_APRESENTADO = sum(PA_VALPRO, na.rm = TRUE),
                VALOR_APROVADO = sum(PA_VALAPR, na.rm = TRUE),
                N_REGISTROS = .N),
            by = .(PA_MVM, PA_CMP, CNES = PA_CODUNI, PA_GESTAO, PA_PROC_ID, CBO = PA_CBOCOD,
                   PA_UFMUN, PA_TPUPS, PA_TIPPRE, PA_NAT_JUR, PA_TPFIN, PA_DOCORIG, PA_CONDIC, PA_CATEND)]
  log_msg("  %s: %s registros no arquivo; %d linhas agregadas", nome, format(n, big.mark = "."), nrow(out))
  rm(dt); gc(verbose = FALSE)
  out
}

main <- function() {
  dir.create(SIA$dir, recursive = TRUE, showWarnings = FALSE)

  ftp <- tryCatch(listar_sia(), error = function(e) {
    log_msg("FTP do DATASUS indisponível (%s); montando a base com os meses já baixados", conditionMessage(e))
    NULL
  })
  if (is.null(ftp)) { consolidar(SIA$dir, SIA$saida); quit(status = 1) }
  movs <- ftp[, .(assinatura = paste(assinatura, collapse = ";")), by = mvm]
  ctrl <- ler_controle(SIA$controle, "mvm")
  forcar <- argumento("forcar")
  pend <- if (tem_flag("reprocessar-tudo")) movs else
    movs[!ctrl, on = .(mvm, assinatura)]
  if (!is.null(forcar)) pend <- unique(rbind(pend, movs[mvm == forcar]))
  pend <- pend[no_periodo(mvm)]
  # Mais recentes primeiro: o mês novo entra logo; o histórico vem nas execuções seguintes.
  setorder(pend, -mvm)
  log_msg("SIA: %d movimentos no FTP entre %s e %s; %d pendentes; processando até %d",
          nrow(movs), CFG$inicio, CFG$fim, nrow(pend), SIA$max_por_execucao)
  pend <- head(pend, SIA$max_por_execucao)

  falhas <- character()
  inicio <- Sys.time()
  for (m in pend$mvm) {
    if (tempo_esgotado(inicio, argumento("minutos"))) {
      log_msg("Limite de %s minutos atingido; os movimentos restantes ficam para a próxima execução", argumento("minutos"))
      break
    }
    log_msg("Movimento %s", m)
    ok <- tryCatch({
      partes <- lapply(ftp[mvm == m]$nome, ler_parte, mvm = m)
      dt <- rbindlist(partes)
      dt <- dt[, lapply(.SD, sum), by = .(PA_MVM, PA_CMP, CNES, PA_GESTAO, PA_PROC_ID, CBO,
                                          PA_UFMUN, PA_TPUPS, PA_TIPPRE, PA_NAT_JUR, PA_TPFIN, PA_DOCORIG, PA_CONDIC, PA_CATEND),
               .SDcols = c("QTD_APRESENTADA", "QTD_APROVADA", "VALOR_APRESENTADO", "VALOR_APROVADO", "N_REGISTROS")]
      gravar_parquet(dt, file.path(SIA$dir, sprintf("sia_%s.parquet", m)))
      ctrl <- registrar_controle(ctrl, SIA$controle, "mvm", m, pend[mvm == m]$assinatura)
      publicar_parcial(paste("SIA: movimento", m))
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
