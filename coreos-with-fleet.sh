
aws ec2 run-instances \
    --count 3 \
    --image-id ami-66e6680e \
    --instance-type m3.medium \
    --key-name coreos \
    --security-groups coreos \
    --user-data file://cloud-config-with-fleet.yml \
    | jq -r .ReservationId
