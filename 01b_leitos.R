#!/usr/bin/env Rscript
# ------------------------------------------------------------------------------
# 01b - Leitos de PE (CNES-LT, arquivos LTPEaamm.dbc)
#
# Leito é estoque: cada mês do CNES traz os leitos existentes naquele mês. A
# série usa um mês por ano: DEZEMBRO de cada ano e, no ano corrente, o último
# mês publicado. Guarda todos os estabelecimentos do estado, como o
# Leitos_Especialidade.def do TabWin da SES.
#
# Saída: uma partição por mês escolhido em dados/leitos/ e a base consolidada
#   dados/saida/leitos.parquet com
#   COMPETENCIA, CNES, CODUFMUN, TP_LEITO (tipo: 1 cirúrgico ... 7 hospital/dia),
#   CODLEITO (especialidade), TPGESTAO (D dupla, E estadual, M municipal,
#   S/Z sem gestão), QT_EXIST (leitos existentes = Freqüência do TabWin),
#   QT_SUS e QT_NSUS.
#
# Só baixa meses novos ou republicados. Quando o ano corrente ganha um mês
# novo, a partição do mês anterior desse ano é apagada.
# Uso: Rscript 01b_leitos.R [--reprocessar-tudo]
# ------------------------------------------------------------------------------

source("utils.R")

LEITOS <- list(
  ftp      = "ftp://ftp.datasus.gov.br/dissemin/publicos/CNES/200508_/Dados/LT/",
  dir      = file.path(CFG$dir_dados, "leitos"),
  saida    = file.path(CFG$dir_dados, "saida", "leitos.parquet"),
  controle = file.path(CFG$dir_dados, "controle", "leitos_processados.csv"),
  texto    = c("CNES", "CODUFMUN", "TP_LEITO", "CODLEITO", "TPGESTAO"),
  numero   = c("QT_EXIST", "QT_SUS", "QT_NSUS")
)

main <- function() {
  dir.create(LEITOS$dir, recursive = TRUE, showWarnings = FALSE)
  lst <- listar_ftp(LEITOS$ftp)
  padrao <- sprintf("^LT%s(\\d{2})(\\d{2})\\.dbc$", CFG$uf)
  lst <- lst[grepl(padrao, nome, ignore.case = TRUE)]
  lst[, mes := sub(padrao, "20\\1\\2", nome, ignore.case = TRUE)]
  lst <- lst[mes >= CFG$inicio & mes <= CFG$fim]
  # Um mês por ano: dezembro, ou o último publicado no ano corrente
  lst[, ano := substr(mes, 1, 4)]
  alvo <- lst[, .SD[which.max(mes)], by = ano]
  alvo[, assinatura := paste(nome, tamanho, data, sep = "|")]

  # Partições que deixaram de ser o mês de referência do ano
  arqs <- list.files(LEITOS$dir, "^lt_\\d{6}\\.parquet$")
  velhos <- arqs[!sub("^lt_(\\d{6})\\.parquet$", "\\1", arqs) %chin% alvo$mes]
  if (length(velhos)) { log_msg("Removendo partições antigas: %s", paste(velhos, collapse = ", "))
    unlink(file.path(LEITOS$dir, velhos)) }

  ctrl <- ler_controle(LEITOS$controle, "mes")
  ctrl <- ctrl[mes %chin% alvo$mes]
  pend <- if (tem_flag("reprocessar-tudo")) alvo else alvo[!ctrl, on = .(mes, assinatura)]
  log_msg("Leitos: meses de referência %s; %d a processar", paste(alvo$mes, collapse = ", "), nrow(pend))

  falhas <- character()
  for (i in seq_len(nrow(pend))) {
    p <- pend[i]
    ok <- tryCatch({
      lt <- padronizar(baixar_ler(LEITOS$ftp, p$nome), texto = LEITOS$texto, numero = LEITOS$numero)
      lt[, COMPETENCIA := p$mes]
      lt <- lt[, lapply(.SD, sum, na.rm = TRUE), by = .(COMPETENCIA, CNES, CODUFMUN, TP_LEITO, CODLEITO, TPGESTAO),
               .SDcols = LEITOS$numero]
      gravar_parquet(lt, file.path(LEITOS$dir, sprintf("lt_%s.parquet", p$mes)))
      ctrl <- registrar_controle(ctrl, LEITOS$controle, "mes", p$mes, p$assinatura)
      log_msg("  %s: %d linhas, %s leitos existentes", p$nome, nrow(lt), format(sum(lt$QT_EXIST), big.mark = "."))
      TRUE
    }, error = function(e) { log_msg("ERRO em %s: %s", p$nome, conditionMessage(e)); FALSE })
    if (!ok) falhas <- c(falhas, p$nome)
  }
  gravar_csv(ctrl, LEITOS$controle)
  consolidar(LEITOS$dir, LEITOS$saida)
  if (length(falhas)) quit(status = 1)
}

if (sys.nframe() == 0L) main()
