
aws ec2 create-key-pair --key-name coreos \
    | jq -r .KeyMaterial \
    | tee coreos.pem
chmod 400 coreos.pem

aws ec2 create-security-group \
    --group-name coreos \
    --description "CoreOS Security Group"

aws ec2 authorize-security-group-ingress \
    --group-name coreos \
    --protocol tcp \
    --port 22 \
    --cidr $(curl -s http://myip.vg)/32

aws ec2 run-instances \
    --image-id ami-66e6680e \
    --instance-type m3.medium \
    --key-name coreos \
    --security-groups coreos \
    --user-data file://cloud-config.yml \
    | jq -r .ReservationId

aws ec2 authorize-security-group-ingress \
    --group-name coreos \
    --source-group coreos \
    --protocol tcp \
    --port 0-65535
