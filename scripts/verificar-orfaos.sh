#!/usr/bin/env bash
# Lista os recursos que sobraram na conta depois do destruir-ambiente (so leitura).
# Ignora os recursos do proprio Academy (item 1.3 do plano da F1): Lambdas RedshiftOverwatch,
# ModLabRole, RoleCreationFunction, MainMonitoringFunction e RedshiftEventSubscription, o
# topico SNS RedshiftSNS e o bucket do state (S3 nao e verificado).
#
# Uso: scripts/verificar-orfaos.sh
# Saida: 0 sem orfaos, 1 com orfaos, 2 se nao conseguir consultar a conta.
# Variaveis: AWS_REGION (padrao us-east-1)
set -euo pipefail

export AWS_DEFAULT_REGION="${AWS_REGION:-us-east-1}"
export AWS_PAGER=""

if ! conta=$(aws sts get-caller-identity --query Account --output text 2>&1); then
  echo "Credenciais AWS invalidas ou expiradas: rode scripts/atualizar-credenciais.sh. Detalhe: $conta" >&2
  exit 2
fi
echo "Conta $conta, regiao $AWS_DEFAULT_REGION"

total=0

# checar <descricao> <comando aws ...>: o comando imprime um item por linha (texto).
checar() {
  local descricao="$1" saida itens
  shift
  if ! saida=$("$@" --output text 2>&1); then
    echo "ERRO ao listar $descricao: $saida" >&2
    exit 2
  fi
  itens=$(tr '\t' ' ' <<< "$saida" | sed '/^None$/d; /^[[:space:]]*$/d')
  if [[ -z "$itens" ]]; then
    printf 'OK     %s\n' "$descricao"
  else
    local n
    n=$(wc -l <<< "$itens")
    total=$((total + n))
    printf 'ORFAO  %s (%d)\n' "$descricao" "$n"
    while IFS= read -r item; do
      printf '         %s\n' "$item"
    done <<< "$itens"
  fi
}

vpc=$(aws ec2 describe-vpcs --filters Name=is-default,Values=true --query 'Vpcs[0].VpcId' --output text)

checar "clusters EKS" \
  aws eks list-clusters --query 'clusters[]'
checar "load balancers" \
  aws elbv2 describe-load-balancers --query 'LoadBalancers[].[LoadBalancerName,DNSName]'
checar "target groups" \
  aws elbv2 describe-target-groups --query 'TargetGroups[].TargetGroupName'
checar "instancias RDS mecanica-*" \
  aws rds describe-db-instances --query "DBInstances[?starts_with(DBInstanceIdentifier, 'mecanica-')].DBInstanceIdentifier"
checar "DB subnet groups mecanica-*" \
  aws rds describe-db-subnet-groups --query "DBSubnetGroups[?starts_with(DBSubnetGroupName, 'mecanica-')].DBSubnetGroupName"
checar "instancias EC2 do cluster" \
  aws ec2 describe-instances \
    --filters Name=tag-key,Values=eks:cluster-name Name=instance-state-name,Values=pending,running,stopping,stopped \
    --query 'Reservations[].Instances[].[InstanceId,State.Name]'
checar "auto scaling groups eks-*" \
  aws autoscaling describe-auto-scaling-groups \
    --query "AutoScalingGroups[?starts_with(AutoScalingGroupName, 'eks-')].AutoScalingGroupName"
checar "ENIs available na VPC default" \
  aws ec2 describe-network-interfaces --filters "Name=vpc-id,Values=$vpc" Name=status,Values=available \
    --query 'NetworkInterfaces[].[NetworkInterfaceId,Description]'
checar "volumes EBS available" \
  aws ec2 describe-volumes --filters Name=status,Values=available --query 'Volumes[].[VolumeId,Size]'
checar "security groups mecanica-*/eks-cluster-sg-*" \
  aws ec2 describe-security-groups \
    --query "SecurityGroups[?starts_with(GroupName, 'mecanica-') || starts_with(GroupName, 'eks-cluster-sg-')].[GroupId,GroupName]"
checar "launch templates mecanica-*/eks-*" \
  aws ec2 describe-launch-templates \
    --query "LaunchTemplates[?starts_with(LaunchTemplateName, 'mecanica-') || starts_with(LaunchTemplateName, 'eks-')].LaunchTemplateName"
checar "Elastic IPs" \
  aws ec2 describe-addresses --query 'Addresses[].[AllocationId,PublicIp]'
checar "repositorios ECR mecanica-*" \
  aws ecr describe-repositories --query "repositories[?starts_with(repositoryName, 'mecanica-')].repositoryName"
checar "secrets mecanica-*/mercadopago-*" \
  aws secretsmanager list-secrets \
    --query "SecretList[?starts_with(Name, 'mecanica-') || starts_with(Name, 'mercadopago-')].Name"
checar "parametros SSM /mecanica/" \
  aws ssm get-parameters-by-path --path /mecanica/ --recursive --query 'Parameters[].Name'
checar "Lambdas mecanica-*" \
  aws lambda list-functions --query "Functions[?starts_with(FunctionName, 'mecanica-')].FunctionName"
checar "log groups *mecanica*" \
  aws logs describe-log-groups --query "logGroups[?contains(logGroupName, 'mecanica')].logGroupName"
checar "HTTP APIs" \
  aws apigatewayv2 get-apis --query 'Items[].[ApiId,Name]'
checar "filas SQS" \
  aws sqs list-queues --query 'QueueUrls[]'
checar "topicos SNS (exceto RedshiftSNS)" \
  aws sns list-topics --query "Topics[?!ends_with(TopicArn, ':RedshiftSNS')].TopicArn"
checar "tabelas DynamoDB" \
  aws dynamodb list-tables --query 'TableNames[]'

echo
if [[ "$total" -eq 0 ]]; then
  echo "Nenhum recurso orfao."
  exit 0
fi
echo "$total recurso(s) orfao(s)."
exit 1
