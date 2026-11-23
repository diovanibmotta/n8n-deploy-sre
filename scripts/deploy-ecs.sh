#!/usr/bin/env bash
# Deploy em ECS trocando a tag da imagem na task definition.
#
# Uso:
#   deploy-ecs.sh discover <alvo>
#   deploy-ecs.sh deploy   <alvo> <tag> [--apply]
#   deploy-ecs.sh rollback <alvo>
#
# Sem --apply, "deploy" roda em dry-run (nao altera nada).
# Alvos sao definidos em um arquivo de configuracao (ver deploy-targets.example.conf),
# indicado por DEPLOY_CONFIG (default: ./deploy-targets.conf).
#
# Requisitos: aws CLI v2 e Python 3 no PATH.

set -euo pipefail

CONFIG_FILE="${DEPLOY_CONFIG:-./deploy-targets.conf}"
STATE_DIR="${STATE_DIR:-./.deploy-state}"

die() { echo "ERRO: $*" >&2; exit 1; }
log() { echo "[$(date +%H:%M:%S)] $*"; }
need() { command -v "$1" >/dev/null 2>&1 || die "'$1' nao encontrado no PATH"; }

PY=""
find_python() {
  for c in python3 python; do
    if command -v "$c" >/dev/null 2>&1 && "$c" -c 'import sys; sys.exit(0 if sys.version_info[0]==3 else 1)' 2>/dev/null; then
      PY="$c"; return 0
    fi
  done
  die "python 3 nao encontrado no PATH"
}

# Manipula o JSON da task definition (stdin).
# modos: image <container> | newtd <container> <image>
td_json() {
  "$PY" -I -c '
import json, sys
mode, name = sys.argv[1], sys.argv[2]
td = json.load(sys.stdin)["taskDefinition"]
if mode == "image":
    for c in td["containerDefinitions"]:
        if c["name"] == name:
            print(c["image"]); break
else:
    for c in td["containerDefinitions"]:
        if c["name"] == name:
            c["image"] = sys.argv[3]
    for k in ("taskDefinitionArn","revision","status","requiresAttributes","compatibilities",
              "registeredAt","registeredBy","deregisteredAt"):
        td.pop(k, None)
    print(json.dumps({k: v for k, v in td.items() if v is not None}))
' "$@"
}

# Carrega as variaveis do alvo: T_<NOME>_<CAMPO>, NOME em maiusculas, nao alfanumerico vira "_".
load_target() {
  TARGET="${1:-}"; [[ -n "$TARGET" ]] || die "alvo nao informado"
  [[ -f "$CONFIG_FILE" ]] || die "config nao encontrada: $CONFIG_FILE (defina DEPLOY_CONFIG)"
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"
  local key; key="$(tr '[:lower:]' '[:upper:]' <<<"$TARGET" | tr -c 'A-Z0-9\n' '_')"
  get() { local v="T_${key}_$1"; echo "${!v:-}"; }
  PROFILE="$(get PROFILE)"; ACCOUNT="$(get ACCOUNT)"; REGION="$(get REGION)"
  CLUSTER="$(get CLUSTER)"; SERVICES="$(get SERVICES)"; CONTAINER="$(get CONTAINER)"
  ECR_PROFILE="$(get ECR_PROFILE)"; ECR_ACCOUNT="$(get ECR_ACCOUNT)"; ECR_REGION="$(get ECR_REGION)"
  for f in PROFILE ACCOUNT REGION CLUSTER SERVICES; do
    [[ -n "${!f}" ]] || die "alvo '$TARGET': campo $f ausente em $CONFIG_FILE"
  done
  AWS_D=(aws --profile "$PROFILE" --region "$REGION")
  AWS_E=()
  if [[ -n "$ECR_PROFILE" && -n "$ECR_ACCOUNT" && -n "$ECR_REGION" ]]; then
    AWS_E=(aws --profile "$ECR_PROFILE" --region "$ECR_REGION")
  fi
}

check_account() {  # $1=array-name $2=conta esperada
  local -n arr="$1"; local acct
  acct="$("${arr[@]}" sts get-caller-identity --query Account --output text 2>&1)" \
    || die "sem credencial para profile ${arr[2]} (faca login: aws sso login --profile ${arr[2]})"
  [[ "$acct" == "$2" ]] || die "conta ativa $acct != esperada $2 (profile ${arr[2]})"
  log "profile ${arr[2]} -> conta $acct OK"
}

preflight() {
  need aws; find_python
  check_account AWS_D "$ACCOUNT"
  if [[ ${#AWS_E[@]} -gt 0 ]]; then check_account AWS_E "$ECR_ACCOUNT"; fi
}

verify_image() {  # $1=imagem atual  $2=tag
  local reg="${1%%/*}" path="${1#*/}"; path="${path%%[:@]*}"
  if [[ ${#AWS_E[@]} -gt 0 && "$reg" == "$ECR_ACCOUNT.dkr.ecr.$ECR_REGION.amazonaws.com" ]]; then
    "${AWS_E[@]}" ecr describe-images --repository-name "$path" --image-ids imageTag="$2" \
      --query 'imageDetails[0].imageDigest' --output text >/dev/null \
      || die "tag $2 nao existe no ECR repo $path"
    log "  tag $2 existe no ECR ($path)"
  else
    log "  AVISO: existencia da tag NAO verificada (registry: $reg)"
  fi
}

deploy_service() {  # $1=service $2=tag $3=apply(0/1)
  local svc="$1" tag="$2" apply="$3" cname="${CONTAINER:-$1}" cur_arn td old_img new_img new_td new_arn
  cur_arn="$("${AWS_D[@]}" ecs describe-services --cluster "$CLUSTER" --services "$svc" \
    --query 'services[0].taskDefinition' --output text 2>/dev/null || true)"
  [[ -n "$cur_arn" && "$cur_arn" != "None" ]] || die "[$svc] service nao encontrado em $CLUSTER"

  td="$("${AWS_D[@]}" ecs describe-task-definition --task-definition "$cur_arn" --output json)"
  old_img="$(td_json image "$cname" <<<"$td")"
  [[ -n "$old_img" ]] || die "[$svc] nenhum container com nome '$cname' na task definition"
  new_img="$(sed -E 's#([:@][^/]*)?$##' <<<"$old_img"):$tag"

  log "[$svc]"
  echo "  atual : $old_img"
  echo "  novo  : $new_img"
  [[ "$old_img" != "$new_img" ]] || { log "  ja esta na tag $tag, nada a fazer"; return 0; }
  verify_image "$old_img" "$tag"
  if [[ "$apply" -ne 1 ]]; then log "  dry-run: nada registrado"; return 0; fi

  new_td="$(td_json newtd "$cname" "$new_img" <<<"$td")"
  mkdir -p "$STATE_DIR"
  echo "$cur_arn" > "$STATE_DIR/$CLUSTER.$svc.previous"
  new_arn="$("${AWS_D[@]}" ecs register-task-definition --cli-input-json "$new_td" \
    --query 'taskDefinition.taskDefinitionArn' --output text)"
  log "  nova revisao: $new_arn"
  "${AWS_D[@]}" ecs update-service --cluster "$CLUSTER" --service "$svc" \
    --task-definition "$new_arn" --force-new-deployment >/dev/null
  log "  update-service enviado"
}

wait_stable() {
  for svc in $SERVICES; do
    log "[$svc] aguardando services-stable..."
    "${AWS_D[@]}" ecs wait services-stable --cluster "$CLUSTER" --services "$svc" \
      || { echo "ERRO: [$svc] nao estabilizou. Rollback: $0 rollback $TARGET" >&2; return 1; }
    "${AWS_D[@]}" ecs describe-services --cluster "$CLUSTER" --services "$svc" \
      --query 'services[0].{running:runningCount,desired:desiredCount,td:taskDefinition}' --output table
  done
}

cmd_discover() {
  load_target "${1:-}"; need aws; check_account AWS_D "$ACCOUNT"
  for c in $("${AWS_D[@]}" ecs list-clusters --query 'clusterArns[]' --output text); do
    echo "## ${c##*/}"
    "${AWS_D[@]}" ecs list-services --cluster "$c" --query 'serviceArns[]' --output text \
      | tr '\t' '\n' | sed 's#.*/#  #'
  done
}

cmd_deploy() {
  local tag="${2:-}" apply=0
  [[ -n "${1:-}" && -n "$tag" ]] || die "uso: deploy <alvo> <tag> [--apply]"
  [[ "${3:-}" == "--apply" ]] && apply=1
  [[ "$tag" != "latest" ]] || die "tag 'latest' nao permitida"
  load_target "$1"; preflight
  log "Alvo: $TARGET | cluster: $CLUSTER | regiao: $REGION | tag: $tag | apply=$apply"
  if [[ "$apply" -eq 1 ]]; then
    read -r -p "Confirma deploy ($TARGET -> $tag)? Digite o nome do alvo: " ans
    [[ "$ans" == "$TARGET" ]] || die "cancelado"
    mkdir -p "$STATE_DIR"; rm -f "$STATE_DIR/$CLUSTER".*.previous
  fi
  for svc in $SERVICES; do deploy_service "$svc" "$tag" "$apply"; done
  if [[ "$apply" -eq 1 ]]; then wait_stable; fi
  log "concluido"
}

cmd_rollback() {
  load_target "${1:-}"; need aws; check_account AWS_D "$ACCOUNT"
  read -r -p "Rollback de $TARGET para a revisao anterior? Digite o nome do alvo: " ans
  [[ "$ans" == "$TARGET" ]] || die "cancelado"
  local rolled=0
  for svc in $SERVICES; do
    local f="$STATE_DIR/$CLUSTER.$svc.previous"
    [[ -f "$f" ]] || { log "[$svc] sem estado anterior, nao alterado"; continue; }
    "${AWS_D[@]}" ecs update-service --cluster "$CLUSTER" --service "$svc" \
      --task-definition "$(cat "$f")" --force-new-deployment >/dev/null
    log "[$svc] rollback para $(cat "$f")"
    rolled=$((rolled + 1))
  done
  [[ "$rolled" -gt 0 ]] || die "nenhum service com estado anterior para reverter"
  wait_stable
}

case "${1:-}" in
  discover) shift; cmd_discover "$@" ;;
  deploy)   shift; cmd_deploy "$@" ;;
  rollback) shift; cmd_rollback "$@" ;;
  *) sed -n '2,12p' "$0"; exit 1 ;;
esac
