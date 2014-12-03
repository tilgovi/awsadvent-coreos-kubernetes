# What's a CoreOS?

CoreOS is a fork of CrOS, the operating system that powers Google
Chrome laptops.  CrOS is a highly customized flavor of Gentoo that
can be entirely built in one-shot on a host Linux machine.  CoreOS
is a minimal Linux/Systemd opperating system with no package
manager.  It is intended for servers that will be hosting virtual
machines.

CoreOS has "Fast Patch" and Google's Omaha updating system as well
as CoreUpdate from the CoreOS folks.  The A/B upgrade system from
CrOS means updated OS images are downloaded to the non-active
partition.  If the upgrade works, great!  If not, we roll back to
the partition that still exists with the old version.  CoreUpdate
also has a web interface to allow you to control what gets updated
on your cluster & when that action happens.

While not being tied specifically to LXC, CoreOS comes with Docker
"batteries included".  Docker runs out of the box with ease.  The
team may add support for an array of other virtualization
technologies on Linux but today CoreOS is known for it's Docker
integration.

CoreOS also includes Etcd, a useful Raft-based key/value store. You
can use this to store cluster-wide configuration & and to provide
look-up data to all your nodes.

Fleet is another CoreOS built-in service that can optionally be
enabled.  Fleet takes the systemd and stretches it so that it is
multi-machine aware.  You can define services or groups of services
in a systemd syntax and deploy them to your cluster.

CoreOS has alpha, beta & stable streams of their OS images and the
alpha channel gets updates often.  The CoreOS project publishes
images in many formats, including AWS images in all regions.  They
additionally share a ready-to-go basic AWS CloudFormation template
from their download page.

# Prerequisites

Today we are going to show how you can launch Google's Kubernetes on
Amazon using CoreOS.  In order to play along you need the following
checklist completed:

-   [ ] AWS account acquired
-   [ ] AWS\_ACCESS\_KEY\_ID environment variable exported
-   [ ] AWS\_SECRET\_ACCESS\_KEY environment variable exported
-   [ ] AWS\_DEFAULT\_REGION environment variable exported
-   [ ] Amazon awscli tools <http://aws.amazon.com/cli> installed
-   [ ] JQ CLI JSON tool <http://stedolan.github.io/jq/> installed

You should be able to execute the following, to print a list of your
EC2 Key-Pairs, before continuing:

    aws ec2 describe-key-pairs|jq '.KeyPairs|.[].KeyName'

# CoreOS on Amazon EC2

Let's launch a single instances of CoreOS just so we can see it work
by itself. Here we create a small a YAML file for AWS 'userdata'.
In it we tell CoreOS that we don't want automatic reboot with an
update (we may prefer to manage it manually in our prod cluster.  If
you like automatic then don't specify anything & you'll get the
default.)

Our super-basic <span class="underline">cloud-config.yml</span> file looks like so:

    #cloud-config

    coreos:
      update:
        group: alpha
        reboot-strategy: off

Here we use 'awscli' to create a new Key-Pair:

    aws ec2 create-key-pair --key-name coreos \
        | jq -r .KeyMaterial \
        | tee coreos.pem
    chmod 400 coreos.pem

We'll also need a security group for CoreOS instances:

    aws ec2 create-security-group \
        --group-name coreos \
        --description "CoreOS Security Group"

Let's allow traffic from our laptop/desktop to SSH:

    aws ec2 authorize-security-group-ingress \
        --group-name coreos \
        --protocol tcp \
        --port 22 \
        --cidr $(curl -s http://myip.vg)/32

Now let's launch a single CoreOS Amazon Instance:

    aws ec2 run-instances \
        --image-id ami-66e6680e \
        --instance-type m3.medium \
        --key-name coreos \
        --security-groups coreos \
        --user-data file://cloud-config.yml \
        | jq -r .ReservationId

# Running a Docker Instance The Old Fashioned Way

Login to our newly launched CoreOS EC2 node:

    aws ec2 describe-instances ;# <- look
    ssh -i coreos.pem core@NEW_COREOS_AWS_NODE_HOSTNAME

Start a Docker instance interactively in the foreground:

    docker run -i -t --rm --name hello busybox /bin/echo 'hullo, world!'

OK.  Now terminate that machine (AWS Console or CLI).  We need more
than just plain ol' docker.  To run a cluster of containers we need
something to schedule & monitor the containers across all our nodes.

# Starting Etcd When CoreOS Launches

The next thing we'll need is to have etcd started with our node.
Etcd will help our nodes with cluster configuration & discovery.
It's also needed by Fleet.

Here is a (partial) Cloud Config userdata file showing etcd being
configured & started:

    #cloud-config

    coreos:
      etcd:
        discovery: [THE URL FROM CALLING `curl -s http://discovery.etcd.io/new`]
        addr: $private_ipv4:4001
        peer-addr: $private_ipv4:7001
      units:
      - name: etcd.service
        command: start

You need to use a different discovery URL (above) for every cluster
launch.  This is noted in the etcd documentation.  Etcd uses the
discovery URL to hint to nodes about peers for a given cluster.  You
can (and probably should if you get serious) run your own internal
etcd cluster just for discovery. Here's the [project page](https://github.com/coreos/etcd) for more
information on etcd.

# Starting Fleetd When CoreOS Launches

Once we have etcd running on every node we can start up Fleet, our
low-level cluster-aware systemd coordinator.

    #cloud-config

    coreos:
      etcd:
        discovery: [THE URL FROM CALLING `curl -s http://discovery.etcd.io/new`]
        addr: $private_ipv4:4001
        peer-addr: $private_ipv4:7001
      units:
      - name: etcd.service
        command: start
      - name: fleet.socket
        command: start
      - name: fleet.service
        command: start

We need to open internal traffic between nodes so that etcd & fleet
can talk to peers:

    aws ec2 authorize-security-group-ingress \
        --group-name coreos \
        --source-group coreos \
        --protocol tcp \
        --port 0-65535

Let's launch a small cluster of 3 coreos-with-fleet instances:

    aws ec2 run-instances \
        --count 3 \
        --image-id ami-66e6680e \
        --instance-type m3.medium \
        --key-name coreos \
        --security-groups coreos \
        --user-data file://cloud-config-with-fleet.yml \
        | jq -r .ReservationId

# Using Fleet With CoreOS to Launch a Container

Starting A Docker Instance Via Fleet

    [Unit]
    Description=MyApp
    After=docker.service
    Requires=docker.service

    [Service]
    TimeoutStartSec=0
    ExecStartPre=-/usr/bin/docker kill busybox1
    ExecStartPre=-/usr/bin/docker rm busybox1
    ExecStartPre=/usr/bin/docker pull busybox
    ExecStart=/usr/bin/docker run --name busybox1 busybox /bin/sh -c "while true; do echo Hello World; sleep 1; done"
    ExecStop=/usr/bin/docker stop busybox1

Login to one of the nodes in our new 3-node cluster:

    ssh-add coreos.pem
    scp myapp.service core@ec2-54-211-93-34.compute-1.amazonaws.com:
    ssh -A core@ec2-54-211-93-34.compute-1.amazonaws.com

Now use fleetctl to start your service on the cluster:

    fleetctl list-machines
    fleetctl list-units
    fleetctl start myapp.service
    fleetctl list-units
    fleetctl status myapp.service

NOTE: There's a way to use the FLEETCTL\_TUNNEL environment variable
in order to use fleetctl locally on your laptop/desktop.  I'll leave
this as a viewer exercise.

Fleet is capable of tracking containers that fail (via systemd
signals).  It will reschedule a container for another node if
needed.  Read more about HA services with fleet [here](https://coreos.com/docs/launching-containers/launching/launching-containers-fleet/#run-a-high-availability-service).

Registry/Discovery feels a little clunky to me (no offense CoreOS
folks).  I don't like having to manage separate "sidekick" or
"ambassador" containers just so I can discover & monitor containers.
You can read more about Fleet discovery patterns [here](https://coreos.com/docs/launching-containers/launching/launching-containers-fleet/#run-an-external-service-sidekick).

There's no "volume" abstraction with Fleet.  There's not really a
cohesive "pod" definition.  Well there is a way to make a "pod" but
the config would be spread out in many separate systemd unit files.
There's no A/B upgrade/rollback for containers (that I know of) with
Fleet.

For these reasons, we need to keep on looking.  Next up: Kubernetes.

# What's Kubernetes?

Kubernetes is a higher-level platform-as-service than CoreOS
currently offers out of the box.  It was born out of the experience
of running GCE at Google.  It still is in it's early stages but I
believe it will become a stable useful tool, like CoreOS, very
quickly.

Kubernetes has an easy-to-configure "Pods" abstraction where all
containers that work together are defined in one YAML file.  Go get
some more information [here](https://github.com/GoogleCloudPlatform/kubernetes/blob/master/docs/pods.md). Pods can be given Labels in their
configuration.  Labels can be used in filters & actions in a way
similar to AWS.

Kubernetes has an abstraction for volumes.  These volumes can be
shared to Pods & containers from the host machine.  Find out more
about volumes [here.](https://github.com/GoogleCloudPlatform/kubernetes/blob/master/docs/volumes.md)

To coordinate replicas (for scaling) of Pods, Kubernetes has the
Replication Controller that coordinates maintaining N Pods in place
on the running cluster.  All of the information needed for the Pod &
replication is maintained in the configuration for replications
controllers.  To go from 8 replicates to 11 is just increment a
number.  It's the equivalent of AWS AutoScale groups but for Docker
Pods. Additionally there are features that allow for rolling
upgrades of a new version of a Pod (and the ability to rollback an
unhealthy upgrade). More information is found [here](https://github.com/GoogleCloudPlatform/kubernetes/blob/master/docs/replication-controller.md).

Kubernetes Services are used to load-balance across all the active
replicates for a pod.  Find more information [here](https://github.com/GoogleCloudPlatform/kubernetes/blob/master/docs/services.md).

# A Virtual Network for Kubernetes With CoreOS Flannel

By default an local private network interface (docker0) is
configured for Docker guest instances when Docker is started.  This
network routes traffic to & from the host machine & all docker guest
instances.  It doesn't route traffic to other host machines or other
host machine's docker containers though.

To really have pods communicating easily across machines, we need a
route-able sub-net for our docker instances across the entire cluster
of our Docker hosts.  This way every docker container in the cluster
can route traffic to/from every other container.  This also means
registry & discovery can contain IP addresses that work & no fancy
proxy hacks are needed to get from point A to point B.

Kubernetes expects this route-able internal network.  Thankfully the
people at CoreOS came up with a solution (currently in Beta).  It's
called "Flannel" (formally known as "Rudder").

To enable a Flannel private network just download & install it on
CoreOS before starting Docker. Also you must tell Docker to use the
private network created by flannel in place of the default.

Below is a (partial) cloud-config file showing fleetd being
downloaded & started.  It also shows a custom Docker config added
(to override the default systemd configuration for Docker).  This is
needed to use the Flannel network for Docker.

    #cloud-config

    coreos:
      units:
      - name: flannel-download.service
        command: start
        content: |
          [Unit]
          After=network-online.target
          Requires=network-online.target
          [Service]
          ExecStart=/usr/bin/wget -N -P /opt/bin https://s3.amazonaws.com/third-party-binaries/flanneld
          ExecStart=/usr/bin/chmod +x /opt/bin/flanneld
          RemainAfterExit=yes
          Type=oneshot
      - name: flannel.service
        command: start
        content: |
          [Unit]
          After=flannel-download.service etcd.service
          Requires=flannel-download.service etcd.service
          [Service]
          ExecStartPre=/bin/bash -c \"until /usr/bin/etcdctl --no-sync set /coreos.com/network/config '{\\\"Network\\\":\\\"172.24.0.0/16\\\"}' ; do /usr/bin/sleep 1 ; done\"
          ExecStart=/opt/bin/flanneld
          ExecStartPost=/bin/bash -c \"until [ -e /run/flannel/subnet.env ]; do /usr/bin/sleep 1 ; done\"
          [Install]
          WantedBy=multi-user.target
      - name: docker.service
        command: start
        content: |
          [Unit]
          After=flannel.service
          Requires=docker.socket flannel.service
          [Service]
          Environment=\"TMPDIR=/var/tmp/\"
          EnvironmentFile=/run/flannel/subnet.env
          ExecStartPre=/bin/mount --make-rprivate /
          LimitNOFILE=1048576
          LimitNPROC=1048576
          ExecStart=/usr/bin/docker --daemon --storage-driver=btrfs --host=fd:// --bip=${FLANNEL_SUBNET} --mtu=${FLANNEL_MTU}
          [Install]
          WantedBy=multi-user.target

Flannel can be configured to use a number of virtual networking
strategies.  Read more about flannel [here](https://github.com/coreos/flannel).

# Adding Kubernetes To CoreOS

Now that we have a private network that can route traffic for our
docker containers easily across the cluster, we can add Kubernetes
to CoreOS. We'll want to follow the same pattern for cloud-config of
downloading the binaries that didn't come with CoreOS & adding
systemd configuration for their services.

The download part (seen 1st below) is common enough to reuse across
Master & Minion nodes (The 2 main roles in a Kubernetes cluster).
From there the Master does most of the work while the Minion just
runs kube-kublet|kube-proxy & does what it's told.

Download Kubernetes (Partial) Cloud Config (both Master & Minion):

    #cloud-config

    coreos:
      units:
      - name: kube-download.service
        command: start
        content: |
          [Unit]
          After=network-online.target
          Requires=network-online.target
          [Service]
          ExecStart=/usr/bin/wget -N -P /opt/bin http://storage.googleapis.com/kubernetes/apiserver
          ExecStart=/usr/bin/wget -N -P /opt/bin http://storage.googleapis.com/kubernetes/controller-manager
          ExecStart=/usr/bin/wget -N -P /opt/bin http://storage.googleapis.com/kubernetes/kubecfg
          ExecStart=/usr/bin/wget -N -P /opt/bin http://storage.googleapis.com/kubernetes/kubelet
          ExecStart=/usr/bin/wget -N -P /opt/bin http://storage.googleapis.com/kubernetes/proxy
          ExecStart=/usr/bin/wget -N -P /opt/bin http://storage.googleapis.com/kubernetes/scheduler
          ExecStart=/usr/bin/wget -N -P /opt/bin http://storage.googleapis.com/kubernetes/scheduler
          ExecStart=/usr/bin/chmod +x /opt/bin/apiserver
          ExecStart=/usr/bin/chmod +x /opt/bin/controller-manager
          ExecStart=/usr/bin/chmod +x /opt/bin/kubecfg
          ExecStart=/usr/bin/chmod +x /opt/bin/kubelet
          ExecStart=/usr/bin/chmod +x /opt/bin/proxy
          ExecStart=/usr/bin/chmod +x /opt/bin/scheduler
          RemainAfterExit=yes
          Type=oneshot

Master-Specific (Partial) Cloud Config:

    #cloud-config

    coreos:
      fleet:
        metadata: role=master
      units:
      - name: kube-kubelet.service
        command: start
        content: |
          [Unit]
          After=kube-download.service etcd.service
          Requires=kube-download.service etcd.service
          ConditionFileIsExecutable=/opt/bin/kubelet
          [Service]
          ExecStart=/opt/bin/kubelet --address=0.0.0.0 --port=10250 --hostname_override=$private_ipv4 --etcd_servers=http://127.0.0.1:4001 --logtostderr=true
          Restart=always
          RestartSec=10
          [Install]
          WantedBy=multi-user.target
      - name: kube-proxy.service
        command: start
        content: |
          [Unit]
          After=kube-download.service etcd.service
          Requires=kube-download.service etcd.service
          ConditionFileIsExecutable=/opt/bin/proxy
          [Service]
          ExecStart=/opt/bin/proxy --etcd_servers=http://127.0.0.1:4001 --logtostderr=true
          Restart=always
          RestartSec=10
          [Install]
          WantedBy=multi-user.target
      - name: kube-apiserver.service
        command: start
        content: |
          [Unit]
          After=kube-download.service etcd.service
          Requires=kube-download.service etcd.service
          ConditionFileIsExecutable=/opt/bin/apiserver
          [Service]
          ExecStart=/opt/bin/apiserver --address=127.0.0.1 --port=8080 --etcd_servers=http://127.0.0.1:4001 --logtostderr=true
          Restart=always
          RestartSec=10
          [Install]
          WantedBy=multi-user.target
      - name: kube-scheduler.service
        command: start
        content: |
          [Unit]
          After=kube-apiserver.service kube-download.service etcd.service
          Requires=kube-apiserver.service kube-download.service etcd.service
          ConditionFileIsExecutable=/opt/bin/scheduler
          [Service]
          ExecStart=/opt/bin/scheduler --logtostderr=true --master=127.0.0.1:8080
          Restart=always
          RestartSec=10
          [Install]
          WantedBy=multi-user.target
      - name: kube-controller-manager.service
        command: start
        content: |
          [Unit]
          After=kube-apiserver.service kube-download.service etcd.service
          Requires=kube-apiserver.service kube-download.service etcd.service
          ConditionFileIsExecutable=/opt/bin/controller-manager
          [Service]
          ExecStart=/opt/bin/controller-manager --master=127.0.0.1:8080 --logtostderr=true
          Restart=always
          RestartSec=10
          [Install]
          WantedBy=multi-user.target

Minion-Specific (Partial) Cloud Config:

    #cloud-config

    coreos:
      fleet:
        metadata: role=minion
      units:
      - name: kube-kubelet.service
        command: start
        content: |
          [Unit]
          After=kube-download.service etcd.service
          Requires=kube-download.service etcd.service
          ConditionFileIsExecutable=/opt/bin/kubelet
          [Service]
          ExecStart=/opt/bin/kubelet --address=0.0.0.0 --port=10250 --hostname_override=$private_ipv4 --etcd_servers=http://127.0.0.1:4001 --logtostderr=true
          Restart=always
          RestartSec=10
          [Install]
          WantedBy=multi-user.target
      - name: kube-proxy.service
        command: start
        content: |
          [Unit]
          After=kube-download.service etcd.service
          Requires=kube-download.service etcd.service
          ConditionFileIsExecutable=/opt/bin/proxy
          [Service]
          ExecStart=/opt/bin/proxy --etcd_servers=http://127.0.0.1:4001 --logtostderr=true
          Restart=always
          RestartSec=10
          [Install]
          WantedBy=multi-user.target

# Kube-Register

Kube-Register bridges discovery of nodes from CoreOS Fleet into
Kubernetes.  This gives us no-hassle discovery of other Minion nodes
in a Kubernetes cluster.  We only need this service on the Master
node. The Kube-Register project can be found [here](https://github.com/kelseyhightower/kube-register).  (Thanks, Kelsey
Hightower!)

Master Node (Partial) Cloud Config:

    #cloud-config

    coreos:
      units:
      - name: kube-register-download.service
        command: start
        content: |
          [Unit]
          After=network-online.target
          Requires=network-online.target
          [Service]
          ExecStart=/usr/bin/wget -N -P /opt/bin https://s3.amazonaws.com/third-party-binaries/kube-register
          ExecStart=/usr/bin/chmod +x /opt/bin/kube-register
          RemainAfterExit=yes
          Type=oneshot
      - name: kube-register.service
        command: start
        content: |
          [Unit]
          After=kube-apiserver.service kube-register-download.service fleet.socket
          Requires=kube-apiserver.service kube-register-download.service fleet.socket
          ConditionFileIsExecutable=/opt/bin/kube-register
          [Service]
          ExecStart=/opt/bin/kube-register --metadata=role=minion --fleet-endpoint=unix:///var/run/fleet.sock -api-endpoint=http://127.0.0.1:8080
          Restart=always
          RestartSec=10
          [Install]
          WantedBy=multi-user.target

# All Together in an AWS CFN Template with AutoScale

Use this CloudFormation template below.  It's a culmination of the
our progression of launch configurations from above.

In the CloudFormation template we add some things.  We add 3
security groups: 1 Common to all Kubernetes nodes, 1 for Master & 1
for Minion.  We also configure 2 AutoScale groups: 1 for Master & 1
for Minion.  This is so we can have different assertions over each
node type. We only need 1 Master node for a small cluster but we
could grow our Minions to, say, 64 without a problem.

I used YAML here for reasons:
1.  You can add comments at will (unlike JSON).
2.  It converts to JSON in a blink of an eye.

    ---
    AWSTemplateFormatVersion: '2010-09-09'
    Description: 'Kubernetes on CoreOS on EC2'
    Mappings:
      RegionMap:
        ap-northeast-1:
          AMI: ami-f9b08ff8
        ap-southeast-1:
          AMI: ami-c24f6c90
        ap-southeast-2:
          AMI: ami-09117e33
        eu-central-1:
          AMI: ami-56ccfa4b
        eu-west-1:
          AMI: ami-a47fd5d3
        sa-east-1:
          AMI: ami-1104b30c
        us-east-1:
          AMI: ami-66e6680e
        us-west-1:
          AMI: ami-bbfcebfe
        us-west-2:
          AMI: ami-ff8dc5cf
    Parameters:
      DockerCIDR:
        Default: 172.24.0.0/16
        Description: The network CIDR to use with for the docker0 network
          interface. Fleet uses 192.168/16 internally so your choices are
          basically 10/8 or 172.16/12. None-VPC AWS uses 10/8 also.
        Type: String
      AdvertisedIPAddress:
        AllowedValues:
        - private
        - public
        Default: private
        Description: Use 'private' if your etcd cluster is within one region or 'public'
          if it spans regions or cloud providers.
        Type: String
      AllowSSHFrom:
        Default: 0.0.0.0/0
        Description: The net block (CIDR) that SSH is available to.
        Type: String
      ClusterSize:
        Default: '2'
        Description: Number of 'minion' nodes in cluster.
        MaxValue: '256'
        MinValue: '2'
        Type: Number
      DiscoveryURL:
        Description: An unique etcd cluster discovery URL. Grab a new token from https://discovery.etcd.io/new
        Type: String
      InstanceType:
        AllowedValues:
        - m3.medium
        - m3.large
        - m3.xlarge
        - m3.2xlarge
        - c3.large
        - c3.xlarge
        - c3.2xlarge
        - c3.4xlarge
        - c3.8xlarge
        - cc2.8xlarge
        - cr1.8xlarge
        - hi1.4xlarge
        - hs1.8xlarge
        - i2.xlarge
        - i2.2xlarge
        - i2.4xlarge
        - i2.8xlarge
        - r3.large
        - r3.xlarge
        - r3.2xlarge
        - r3.4xlarge
        - r3.8xlarge
        - t2.micro
        - t2.small
        - t2.medium
        ConstraintDescription: Must be a valid EC2 HVM instance type.
        Default: m3.medium
        Description: EC2 instance type (m3.medium, etc).
        Type: String
      KeyPair:
        Description: The name of an EC2 Key Pair to allow SSH access to the instance.
        Type: String
    Resources:
      CoreOSInternalIngressTCP:
        Properties:
          GroupName:
            Ref: KubeSecurityGroup
          IpProtocol: tcp
          FromPort: '0'
          ToPort: '65535'
          SourceSecurityGroupId:
            Fn::GetAtt:
            - KubeSecurityGroup
            - GroupId
        Type: AWS::EC2::SecurityGroupIngress
      CoreOSInternalIngressUDP:
        Properties:
          GroupName:
            Ref: KubeSecurityGroup
          IpProtocol: udp
          FromPort: '0'
          ToPort: '65535'
          SourceSecurityGroupId:
            Fn::GetAtt:
            - KubeSecurityGroup
            - GroupId
        Type: AWS::EC2::SecurityGroupIngress
      KubeSecurityGroup:
        Properties:
          GroupDescription: CoreOS SecurityGroup
          SecurityGroupIngress:
          - CidrIp:
              Ref: AllowSSHFrom
            FromPort: '22'
            IpProtocol: tcp
            ToPort: '22'
        Type: AWS::EC2::SecurityGroup
      KubeMasterSecurityGroup:
        Properties:
          GroupDescription: Master SecurityGroup
        Type: AWS::EC2::SecurityGroup
      KubeMinionSecurityGroup:
        Properties:
          GroupDescription: Minion SecurityGroup
        Type: AWS::EC2::SecurityGroup
      MasterAutoScale:
        Properties:
          AvailabilityZones:
            Fn::GetAZs: ''
          DesiredCapacity: '1'
          LaunchConfigurationName:
            Ref: MasterLaunchConfig
          MaxSize: '2'
          MinSize: '1'
          Tags:
          - Key: Name
            PropagateAtLaunch: true
            Value:
              Ref: AWS::StackName
        Type: AWS::AutoScaling::AutoScalingGroup
      MinionAutoScale:
        Properties:
          AvailabilityZones:
            Fn::GetAZs: ''
          DesiredCapacity:
            Ref: ClusterSize
          LaunchConfigurationName:
            Ref: MinionLaunchConfig
          MaxSize: '256'
          MinSize: '2'
          Tags:
          - Key: Name
            PropagateAtLaunch: true
            Value:
              Ref: AWS::StackName
        Type: AWS::AutoScaling::AutoScalingGroup
      MasterLaunchConfig:
        Properties:
          ImageId:
            Fn::FindInMap:
            - RegionMap
            - Ref: AWS::Region
            - AMI
          InstanceType:
            Ref: InstanceType
          KeyName:
            Ref: KeyPair
          SecurityGroups:
          - Ref: KubeSecurityGroup
          - Ref: KubeMasterSecurityGroup
          UserData:
            Fn::Base64:
              Fn::Join:
              - ""
              - - ! "#cloud-config\n\n"
                - ! "coreos:\n"
                - ! "  etcd:\n"
                - ! "    discovery: "
                - Ref: DiscoveryURL
                - ! "\n"
                - ! "    addr: $"
                - Ref: AdvertisedIPAddress
                - ! "_ipv4:4001\n"
                - ! "    peer-addr: $"
                - Ref: AdvertisedIPAddress
                - ! "_ipv4:7001\n"
                - ! "  fleet:\n"
                - ! "    metadata: role=master\n"
                - ! "  units:\n"
                - ! "    - name: flannel-download.service\n"
                - ! "      command: start\n"
                - ! "      content: |\n"
                - ! "        [Unit]\n"
                - ! "        After=network-online.target\n"
                - ! "        Requires=network-online.target\n"
                - ! "        [Service]\n"
                - ! "        ExecStart=/usr/bin/wget -N -P /opt/bin https://s3.amazonaws.com/third-party-binaries/flanneld\n"
                - ! "        ExecStart=/usr/bin/chmod +x /opt/bin/flanneld\n"
                - ! "        RemainAfterExit=yes\n"
                - ! "        Type=oneshot\n"
                - ! "    - name: kube-download.service\n"
                - ! "      command: start\n"
                - ! "      content: |\n"
                - ! "        [Unit]\n"
                - ! "        After=network-online.target\n"
                - ! "        Requires=network-online.target\n"
                - ! "        [Service]\n"
                - ! "        ExecStart=/usr/bin/wget -N -P /opt/bin http://storage.googleapis.com/kubernetes/apiserver\n"
                - ! "        ExecStart=/usr/bin/wget -N -P /opt/bin http://storage.googleapis.com/kubernetes/controller-manager\n"
                - ! "        ExecStart=/usr/bin/wget -N -P /opt/bin http://storage.googleapis.com/kubernetes/kubecfg\n"
                - ! "        ExecStart=/usr/bin/wget -N -P /opt/bin http://storage.googleapis.com/kubernetes/kubelet\n"
                - ! "        ExecStart=/usr/bin/wget -N -P /opt/bin http://storage.googleapis.com/kubernetes/proxy\n"
                - ! "        ExecStart=/usr/bin/wget -N -P /opt/bin http://storage.googleapis.com/kubernetes/scheduler\n"
                - ! "        ExecStart=/usr/bin/wget -N -P /opt/bin http://storage.googleapis.com/kubernetes/scheduler\n"
                - ! "        ExecStart=/usr/bin/chmod +x /opt/bin/apiserver\n"
                - ! "        ExecStart=/usr/bin/chmod +x /opt/bin/controller-manager\n"
                - ! "        ExecStart=/usr/bin/chmod +x /opt/bin/kubecfg\n"
                - ! "        ExecStart=/usr/bin/chmod +x /opt/bin/kubelet\n"
                - ! "        ExecStart=/usr/bin/chmod +x /opt/bin/proxy\n"
                - ! "        ExecStart=/usr/bin/chmod +x /opt/bin/scheduler\n"
                - ! "        RemainAfterExit=yes\n"
                - ! "        Type=oneshot\n"
                - ! "    - name: kube-register-download.service\n"
                - ! "      command: start\n"
                - ! "      content: |\n"
                - ! "        [Unit]\n"
                - ! "        After=network-online.target\n"
                - ! "        Requires=network-online.target\n"
                - ! "        [Service]\n"
                - ! "        ExecStart=/usr/bin/wget -N -P /opt/bin https://s3.amazonaws.com/third-party-binaries/kube-register\n"
                - ! "        ExecStart=/usr/bin/chmod +x /opt/bin/kube-register\n"
                - ! "        RemainAfterExit=yes\n"
                - ! "        Type=oneshot\n"
                - ! "    - name: etcd.service\n"
                - ! "      command: start\n"
                - ! "    - name: flannel.service\n"
                - ! "      command: start\n"
                - ! "      content: |\n"
                - ! "        [Unit]\n"
                - ! "        After=flannel-download.service etcd.service\n"
                - ! "        Requires=flannel-download.service etcd.service\n"
                - ! "        [Service]\n"
                - ! "        ExecStartPre=/bin/bash -c \"until /usr/bin/etcdctl --no-sync set /coreos.com/network/config '{\\\"Network\\\":\\\""
                - Ref: DockerCIDR
                - ! "\\\"}' ; do /usr/bin/sleep 1 ; done\"\n"
                - ! "        ExecStart=/opt/bin/flanneld\n"
                - ! "        ExecStartPost=/bin/bash -c \"until [ -e /run/flannel/subnet.env ]; do /usr/bin/sleep 1 ; done\"\n"
                - ! "        [Install]\n"
                - ! "        WantedBy=multi-user.target\n"
                - ! "    - name: docker.service\n"
                - ! "      command: start\n"
                - ! "      content: |\n"
                - ! "        [Unit]\n"
                - ! "        After=flannel.service\n"
                - ! "        Requires=docker.socket flannel.service\n"
                - ! "        [Service]\n"
                - ! "        Environment=\"TMPDIR=/var/tmp/\"\n"
                - ! "        EnvironmentFile=/run/flannel/subnet.env\n"
                - ! "        ExecStartPre=/bin/mount --make-rprivate /\n"
                - ! "        LimitNOFILE=1048576\n"
                - ! "        LimitNPROC=1048576\n"
                - ! "        ExecStart=/usr/bin/docker --daemon --storage-driver=btrfs --host=fd:// --bip=${FLANNEL_SUBNET} --mtu=${FLANNEL_MTU}\n"
                - ! "        [Install]\n"
                - ! "        WantedBy=multi-user.target\n"
                - ! "    - name: fleet.socket\n"
                - ! "      command: start\n"
                - ! "    - name: fleet.service\n"
                - ! "      command: start\n"
                - ! "    - name: kube-kubelet.service\n"
                - ! "      command: start\n"
                - ! "      content: |\n"
                - ! "        [Unit]\n"
                - ! "        After=kube-download.service etcd.service\n"
                - ! "        Requires=kube-download.service etcd.service\n"
                - ! "        ConditionFileIsExecutable=/opt/bin/kubelet\n"
                - ! "        [Service]\n"
                - ! "        ExecStart=/opt/bin/kubelet --address=0.0.0.0 --port=10250 --hostname_override=$"
                - Ref: AdvertisedIPAddress
                - ! "_ipv4 --etcd_servers=http://127.0.0.1:4001 --logtostderr=true\n"
                - ! "        Restart=always\n"
                - ! "        RestartSec=10\n"
                - ! "        [Install]\n"
                - ! "        WantedBy=multi-user.target\n"
                - ! "    - name: kube-proxy.service\n"
                - ! "      command: start\n"
                - ! "      content: |\n"
                - ! "        [Unit]\n"
                - ! "        After=kube-download.service etcd.service\n"
                - ! "        Requires=kube-download.service etcd.service\n"
                - ! "        ConditionFileIsExecutable=/opt/bin/proxy\n"
                - ! "        [Service]\n"
                - ! "        ExecStart=/opt/bin/proxy --etcd_servers=http://127.0.0.1:4001 --logtostderr=true\n"
                - ! "        Restart=always\n"
                - ! "        RestartSec=10\n"
                - ! "        [Install]\n"
                - ! "        WantedBy=multi-user.target\n"
                - ! "    - name: kube-apiserver.service\n"
                - ! "      command: start\n"
                - ! "      content: |\n"
                - ! "        [Unit]\n"
                - ! "        After=kube-download.service etcd.service\n"
                - ! "        Requires=kube-download.service etcd.service\n"
                - ! "        ConditionFileIsExecutable=/opt/bin/apiserver\n"
                - ! "        [Service]\n"
                - ! "        ExecStart=/opt/bin/apiserver --address=127.0.0.1 --port=8080 --etcd_servers=http://127.0.0.1:4001 --logtostderr=true\n"
                - ! "        Restart=always\n"
                - ! "        RestartSec=10\n"
                - ! "        [Install]\n"
                - ! "        WantedBy=multi-user.target\n"
                - ! "    - name: kube-scheduler.service\n"
                - ! "      command: start\n"
                - ! "      content: |\n"
                - ! "        [Unit]\n"
                - ! "        After=kube-apiserver.service kube-download.service etcd.service\n"
                - ! "        Requires=kube-apiserver.service kube-download.service etcd.service\n"
                - ! "        ConditionFileIsExecutable=/opt/bin/scheduler\n"
                - ! "        [Service]\n"
                - ! "        ExecStart=/opt/bin/scheduler --logtostderr=true --master=127.0.0.1:8080\n"
                - ! "        Restart=always\n"
                - ! "        RestartSec=10\n"
                - ! "        [Install]\n"
                - ! "        WantedBy=multi-user.target\n"
                - ! "    - name: kube-controller-manager.service\n"
                - ! "      command: start\n"
                - ! "      content: |\n"
                - ! "        [Unit]\n"
                - ! "        After=kube-apiserver.service kube-download.service etcd.service\n"
                - ! "        Requires=kube-apiserver.service kube-download.service etcd.service\n"
                - ! "        ConditionFileIsExecutable=/opt/bin/controller-manager\n"
                - ! "        [Service]\n"
                - ! "        ExecStart=/opt/bin/controller-manager --master=127.0.0.1:8080 --logtostderr=true\n"
                - ! "        Restart=always\n"
                - ! "        RestartSec=10\n"
                - ! "        [Install]\n"
                - ! "        WantedBy=multi-user.target\n"
                - ! "    - name: kube-register.service\n"
                - ! "      command: start\n"
                - ! "      content: |\n"
                - ! "        [Unit]\n"
                - ! "        After=kube-apiserver.service kube-register-download.service fleet.socket\n"
                - ! "        Requires=kube-apiserver.service kube-register-download.service fleet.socket\n"
                - ! "        ConditionFileIsExecutable=/opt/bin/kube-register\n"
                - ! "        [Service]\n"
                - ! "        ExecStart=/opt/bin/kube-register --metadata=role=minion --fleet-endpoint=unix:///var/run/fleet.sock -api-endpoint=http://127.0.0.1:8080\n"
                - ! "        Restart=always\n"
                - ! "        RestartSec=10\n"
                - ! "        [Install]\n"
                - ! "        WantedBy=multi-user.target\n"
                - ! "  update:\n"
                - ! "    group: alpha\n"
                - ! "    reboot-strategy: off\n"
        Type: AWS::AutoScaling::LaunchConfiguration
      MinionLaunchConfig:
        Properties:
          ImageId:
            Fn::FindInMap:
            - RegionMap
            - Ref: AWS::Region
            - AMI
          InstanceType:
            Ref: InstanceType
          KeyName:
            Ref: KeyPair
          SecurityGroups:
          - Ref: KubeSecurityGroup
          - Ref: KubeMinionSecurityGroup
          UserData:
            Fn::Base64:
              Fn::Join:
              - ""
              - - ! "#cloud-config\n\n"
                - ! "coreos:\n"
                - ! "  etcd:\n"
                - ! "    discovery: "
                - Ref: DiscoveryURL
                - ! "\n"
                - ! "    addr: $"
                - Ref: AdvertisedIPAddress
                - ! "_ipv4:4001\n"
                - ! "    peer-addr: $"
                - Ref: AdvertisedIPAddress
                - ! "_ipv4:7001\n"
                - ! "  fleet:\n"
                - ! "    metadata: role=minion\n"
                - ! "  units:\n"
                - ! "    - name: kube-download.service\n"
                - ! "      command: start\n"
                - ! "      content: |\n"
                - ! "        [Unit]\n"
                - ! "        After=network-online.target\n"
                - ! "        Requires=network-online.target\n"
                - ! "        [Service]\n"
                - ! "        ExecStart=/usr/bin/wget -N -P /opt/bin http://storage.googleapis.com/kubernetes/apiserver\n"
                - ! "        ExecStart=/usr/bin/wget -N -P /opt/bin http://storage.googleapis.com/kubernetes/controller-manager\n"
                - ! "        ExecStart=/usr/bin/wget -N -P /opt/bin http://storage.googleapis.com/kubernetes/kubecfg\n"
                - ! "        ExecStart=/usr/bin/wget -N -P /opt/bin http://storage.googleapis.com/kubernetes/kubelet\n"
                - ! "        ExecStart=/usr/bin/wget -N -P /opt/bin http://storage.googleapis.com/kubernetes/proxy\n"
                - ! "        ExecStart=/usr/bin/wget -N -P /opt/bin http://storage.googleapis.com/kubernetes/scheduler\n"
                - ! "        ExecStart=/usr/bin/wget -N -P /opt/bin http://storage.googleapis.com/kubernetes/scheduler\n"
                - ! "        ExecStart=/usr/bin/wget -N -P /opt/bin https://s3.amazonaws.com/third-party-binaries/flanneld\n"
                - ! "        ExecStart=/usr/bin/wget -N -P /opt/bin https://s3.amazonaws.com/third-party-binaries/kube-register\n"
                - ! "        ExecStart=/usr/bin/chmod +x /opt/bin/apiserver\n"
                - ! "        ExecStart=/usr/bin/chmod +x /opt/bin/controller-manager\n"
                - ! "        ExecStart=/usr/bin/chmod +x /opt/bin/flanneld\n"
                - ! "        ExecStart=/usr/bin/chmod +x /opt/bin/kube-register\n"
                - ! "        ExecStart=/usr/bin/chmod +x /opt/bin/kubecfg\n"
                - ! "        ExecStart=/usr/bin/chmod +x /opt/bin/kubelet\n"
                - ! "        ExecStart=/usr/bin/chmod +x /opt/bin/proxy\n"
                - ! "        ExecStart=/usr/bin/chmod +x /opt/bin/scheduler\n"
                - ! "        RemainAfterExit=yes\n"
                - ! "        Type=oneshot\n"
                - ! "    - name: etcd.service\n"
                - ! "      command: start\n"
                - ! "    - name: flannel.service\n"
                - ! "      command: start\n"
                - ! "      content: |\n"
                - ! "        [Unit]\n"
                - ! "        After=kube-download.service etcd.service\n"
                - ! "        Requires=kube-download.service etcd.service\n"
                - ! "        [Service]\n"
                - ! "        ExecStartPre=/bin/bash -c \"until /usr/bin/etcdctl --no-sync set /coreos.com/network/config '{\\\"Network\\\":\\\""
                - Ref: DockerCIDR
                - ! "\\\"}' ; do /usr/bin/sleep 1 ; done\"\n"
                - ! "        ExecStart=/opt/bin/flanneld\n"
                - ! "        ExecStartPost=/bin/bash -c \"until [ -e /run/flannel/subnet.env ]; do /usr/bin/sleep 1 ; done\"\n"
                - ! "        [Install]\n"
                - ! "        WantedBy=multi-user.target\n"
                - ! "    - name: docker.service\n"
                - ! "      command: start\n"
                - ! "      content: |\n"
                - ! "        [Unit]\n"
                - ! "        After=flannel.service\n"
                - ! "        Requires= docker.socket flannel.service\n"
                - ! "        [Service]\n"
                - ! "        Environment=\"TMPDIR=/var/tmp/\"\n"
                - ! "        EnvironmentFile=/run/flannel/subnet.env\n"
                - ! "        ExecStartPre=/bin/mount --make-rprivate /\n"
                - ! "        LimitNOFILE=1048576\n"
                - ! "        LimitNPROC=1048576\n"
                - ! "        ExecStart=/usr/bin/docker --daemon --storage-driver=btrfs --host=fd:// --bip=${FLANNEL_SUBNET} --mtu=${FLANNEL_MTU}\n"
                - ! "        [Install]\n"
                - ! "        WantedBy=multi-user.target\n"
                - ! "    - name: fleet.socket\n"
                - ! "      command: start\n"
                - ! "    - name: fleet.service\n"
                - ! "      command: start\n"
                - ! "    - name: kube-kubelet.service\n"
                - ! "      command: start\n"
                - ! "      content: |\n"
                - ! "        [Unit]\n"
                - ! "        After=kube-download.service etcd.service\n"
                - ! "        Requires=kube-download.service etcd.service\n"
                - ! "        ConditionFileIsExecutable=/opt/bin/kubelet\n"
                - ! "        [Service]\n"
                - ! "        ExecStart=/opt/bin/kubelet --address=0.0.0.0 --port=10250 --hostname_override=$"
                - Ref: AdvertisedIPAddress
                - ! "_ipv4 --etcd_servers=http://127.0.0.1:4001 --logtostderr=true\n"
                - ! "        Restart=always\n"
                - ! "        RestartSec=10\n"
                - ! "        [Install]\n"
                - ! "        WantedBy=multi-user.target\n"
                - ! "    - name: kube-proxy.service\n"
                - ! "      command: start\n"
                - ! "      content: |\n"
                - ! "        [Unit]\n"
                - ! "        After=kube-download.service etcd.service\n"
                - ! "        Requires=kube-download.service etcd.service\n"
                - ! "        ConditionFileIsExecutable=/opt/bin/proxy\n"
                - ! "        [Service]\n"
                - ! "        ExecStart=/opt/bin/proxy --etcd_servers=http://127.0.0.1:4001 --logtostderr=true\n"
                - ! "        Restart=always\n"
                - ! "        RestartSec=10\n"
                - ! "        [Install]\n"
                - ! "        WantedBy=multi-user.target\n"
                - ! "  update:\n"
                - ! "    group: alpha\n"
                - ! "    reboot-strategy: off\n"
        Type: AWS::AutoScaling::LaunchConfiguration

## Converting To JSON Before Launch

    cat kubernetes.yml \
        | ruby -ryaml -rjson -e 'print YAML.load(STDIN.read).to_json' \
        | tee kubernetes.json

If you have another tool you prefer to convert YAML to JSON, then
use that. I have Ruby & Python usually installed on my machines
from other DevOps activities. Either one could be used.

## Launching with AWS Cloud Formation

    aws cloudformation create-stack \
        --stack-name kubernetes \
        --template-body file://kubernetes.json \
        --parameters \
            ParameterKey=DiscoveryURL,ParameterValue="$(curl -s http://discovery.etcd.io/new)" \
            ParameterKey=KeyPair,ParameterValue=coreos

SSH into the master node on the cluster:

    ssh -A core@ec2-54-211-121-17.compute-1.amazonaws.com

We can still use Fleet if we want:

    fleetctl list-machines
    fleetctl list-units

But now we can use Kubernetes also:

    kubecfg list minions
    kubecfg list pods

Looks something like this:
![img](./kubernetes.png)

Here's the [Kubernetes 101 documentation](https://github.com/GoogleCloudPlatform/kubernetes/blob/master/examples/walkthrough/README.md) as a next step.  Happy
deploying!

# Cluster Architecture

Just like people organizations, these clusters change as they scale.
For now it works to have every node run etcd. For now it works to
have a top-of-cluster master that can die & get replaced inside 5
minutes.  These allowances work in the small scale.

In the larger scale, we may need a dedicated etcd cluster. We may
need more up-time from our Kubernetes Master nodes.  The nice thing
about our using containers is that re-configuring things feels a bit
like moving chess pieces on a board (not repainting the scene by
hand).

# Personal Plug

I'm looking for contract work to fill the gaps next year.  You might
need help with Amazon (I've using AWS FT since 2007), Virtualization
or DevOps. I also like programming & new start-ups.  I prefer to
program in Haskell & Purescript.  I'm actively using Purescript with
Amazon's JS SDK (& soon with AWS Lambda). If you need the help,
let's work it out. I'm @dysinger on twitter, dysinger on IRC or send
e-mail to tim on the domain dysinger.net

P.S. You should really learn Haskell. :)
