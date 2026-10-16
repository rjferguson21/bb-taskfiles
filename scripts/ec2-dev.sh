#!/bin/bash
set -eo pipefail

# EC2 dev instance for remote-docker workflows, driven by taskfiles/aws.yml.
# Provisions a key pair, security group, and spot instance; the instance
# installs docker and kernel tuning itself at boot via cloud-config.yaml.
#
# Usage: ec2-dev.sh [-d destroy] [-R recreate / skip destroy prompt]
# Env overrides: INSTANCE_TYPE, VOLUME_SIZE, AMI_ID, SUBNET_ID

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)

INSTANCE_TYPE="${INSTANCE_TYPE:-t3.2xlarge}"
VOLUME_SIZE="${VOLUME_SIZE:-120}"
SSHUSER=ubuntu
action=create
RECREATE=false

while [ -n "$1" ]; do
  case "$1" in
  -d|--destroy-cloud-instance) action=destroy ;;
  -R|--recreate-cloud-instance) RECREATE=true ;;
  -h|--help)
    sed -n '4,9p' "${BASH_SOURCE[0]}" | sed 's/^# \?//'
    exit 0
    ;;
  *) echo "Option $1 not recognized" ;;
  esac
  shift
done

AWSUSERNAME=$(aws sts get-caller-identity --query Arn --output text | awk -F/ '{print $NF}' | tr -d '@')
NAME="${AWSUSERNAME}-dev"
SSHKEY=~/.ssh/${NAME}.pem

function run {
  ssh -i ${SSHKEY} -o StrictHostKeyChecking=no -o IdentitiesOnly=yes ${SSHUSER}@${PublicIP} "$@"
}

# This account's SSO role denies ec2:CreateTags, so instances are identified
# by their key pair name rather than tags.
function find_instance {
  InstId=$(aws ec2 describe-instances --output text \
    --query "Reservations[].Instances[].InstanceId" \
    --filters "Name=key-name,Values=${NAME}" "Name=instance-state-name,Values=running")
}

function destroy {
  find_instance
  if [[ $InstId ]]; then
    echo "aws instances being terminated: ${InstId}"
    if [[ "${RECREATE}" != "true" ]]; then
      read -p "Are you sure you want to delete these instances (y/n)? " -r
      [[ $REPLY =~ ^[Yy]$ ]] || exit 1
    fi
    if ! aws ec2 terminate-instances --instance-ids ${InstId} &>/dev/null; then
      # ec2:TerminateInstances is denied for the SSO role; the instance is a
      # one-time spot with shutdown behavior "terminate", so an OS shutdown
      # terminates it
      echo "API terminate denied; shutting down over ssh instead ..."
      PublicIP=$(aws ec2 describe-instances --output text --instance-ids ${InstId} \
        --query "Reservations[].Instances[].PublicIpAddress")
      run sudo shutdown -h now || true
    fi
    echo -n "Waiting for instance termination..."
    aws ec2 wait instance-terminated --instance-ids ${InstId}
    echo "done"
  else
    echo "You had no running instances."
  fi
  echo "Deleting security group ${NAME} and key pair ${NAME}"
  aws ec2 delete-security-group --group-name ${NAME} &>/dev/null || echo "  (could not delete security group)"
  aws ec2 delete-key-pair --key-name ${NAME} &>/dev/null || echo "  (could not delete key pair)"
  echo "Cloud resource cleanup complete"
}

function ensure_keypair {
  if ! aws ec2 describe-key-pairs --key-names ${NAME} &>/dev/null; then
    echo "Creating key pair ${NAME} ..."
    aws ec2 create-key-pair --key-name ${NAME} --query KeyMaterial --output text >${SSHKEY}
    chmod 600 ${SSHKEY}
  fi
  if [[ ! -f ${SSHKEY} ]]; then
    echo "Key pair ${NAME} exists in AWS but ${SSHKEY} is missing. Cannot continue." >&2
    exit 1
  fi
}

function ensure_security_group {
  if ! aws ec2 describe-security-groups --group-names ${NAME} &>/dev/null; then
    echo "Creating security group ${NAME} ..."
    aws ec2 create-security-group --group-name ${NAME} \
      --description "IP based filtering for ${NAME}" >/dev/null
  fi
  WorkstationIP=$(curl -s http://checkip.amazonaws.com/)
  if ! aws ec2 describe-security-groups --group-names ${NAME} | grep -q "${WorkstationIP}"; then
    echo "Authorizing ${WorkstationIP} in security group ${NAME} ..."
    aws ec2 authorize-security-group-ingress --group-name ${NAME} \
      --protocol all --cidr ${WorkstationIP}/32 >/dev/null
  fi
}

function create {
  find_instance
  if [[ $InstId ]]; then
    if [[ "${RECREATE}" == "true" ]]; then
      destroy
    else
      echo "Reusing existing instance ${InstId}. Pass -R to destroy and recreate."
      return
    fi
  fi

  ensure_keypair
  ensure_security_group

  AMI_ID="${AMI_ID:-$(aws ssm get-parameter \
    --name /aws/service/canonical/ubuntu/server/22.04/stable/current/amd64/hvm/ebs-gp2/ami-id \
    --query Parameter.Value --output text)}"

  echo "Launching ${INSTANCE_TYPE} spot instance from ${AMI_ID} ..."
  InstId=$(aws ec2 run-instances --output text --query 'Instances[0].InstanceId' \
    --count 1 --image-id ${AMI_ID} \
    --instance-type ${INSTANCE_TYPE} \
    ${SUBNET_ID:+--subnet-id ${SUBNET_ID}} \
    --key-name ${NAME} \
    --security-groups ${NAME} \
    --instance-initiated-shutdown-behavior terminate \
    --instance-market-options 'MarketType=spot,SpotOptions={SpotInstanceType=one-time}' \
    --block-device-mappings "DeviceName=/dev/sda1,Ebs={DeleteOnTermination=true,VolumeType=gp3,VolumeSize=${VOLUME_SIZE},Encrypted=true}" \
    --user-data file://${SCRIPT_DIR}/cloud-config.yaml)

  echo "Waiting for instance ${InstId} to be ready ..."
  aws ec2 wait instance-running --instance-ids ${InstId}
  PublicIP=$(aws ec2 describe-instances --output text --instance-ids ${InstId} \
    --query "Reservations[].Instances[].PublicIpAddress")

  ssh-keygen -f "${HOME}/.ssh/known_hosts" -R "${PublicIP}" &>/dev/null || true
  until run hostname &>/dev/null; do
    echo "Waiting for ssh ..."
    sleep 5
  done

  echo "Waiting for cloud-init to finish (apt upgrade + docker install) ..."
  run cloud-init status --wait
  run docker ps >/dev/null

  echo
  echo "Instance ${InstId} is ready at ${PublicIP}, docker is up."
  echo "ssh to instance: ssh -i ${SSHKEY} ${SSHUSER}@${PublicIP}"
}

${action}
