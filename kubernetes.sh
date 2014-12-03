
aws cloudformation create-stack \
    --stack-name kubernetes \
    --template-body file://kubernetes.json \
    --parameters \
        ParameterKey=DiscoveryURL,ParameterValue="$(curl -s http://discovery.etcd.io/new)" \
        ParameterKey=KeyPair,ParameterValue=coreos
