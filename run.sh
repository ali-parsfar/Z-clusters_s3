#!/bin/bash
# Description = This bash script > With using eksctl , creates a simple eks cluster with AWS-S3-CSI-Driver .
# HowToUse = " % ./run.sh| tee -a output.md "
# Duration = Around 15 minutes
# https://docs.aws.amazon.com/AmazonS3/latest/userguide/mountpoint-installation.html
# https://github.com/awslabs/mountpoint-s3-csi-driver/blob/main/docs/install.md
# https://github.com/awslabs/mountpoint-s3-csi-driver/tree/main/examples/kubernetes/static_provisioning
# https://github.com/awslabs/mountpoint-s3/blob/main/doc/CONFIGURATION.md#iam-permissions
# https://github.com/awslabs/mountpoint-s3-csi-driver


### ### ### ### ### ### ### ### ### ### ### ### ### ### ### ### ###
### Variables:
export REGION=ap-southeast-2
export CLUSTER_NAME=s3
export CLUSTER=$CLUSTER_NAME
export AWS_ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
export ACC=$AWS_ACCOUNT_ID
export AWS_DEFAULT_REGION=$REGION
export CLUSTER_VER=1.27



echo " 
### PARAMETERES IN USE: >>> 
CLUSTER_NAME=$CLUSTER_NAME  
REGION=$REGION 
AWS_DEFAULT_REGION=$AWS_DEFAULT_REGION
AWS_ACCOUNT_ID=$AWS_ACCOUNT_ID

"

if [[ $1 == "cleanup" ]] ;
then 


### ### ### ### ### ### ### ### ### ### ### ### ### ### ### ### ###
echo " 
### ### ### ### ### ### ### ### ### ### ### ### ### ### ### ### ###
 ### 0- Cleanup  ....... :
 "
# Do Cleanup
kubectl delete pod --all
kubectl delete pvc --all
kubectl delete pv --all
helm uninstall aws-mountpoint-s3-csi-driver --namespace kube-system

eksctl delete iamserviceaccount \
    --name s3-csi-driver-sa \
    --namespace kube-system \
    --cluster $CLUSTER_NAME \
    --region $REGION
exit 1
fi;

### ### ### ### ### ### ### ### ### ### ### ### ### ### ### ### ###
echo " ### ### ### ### ### ### ### ### ### ### ### ### ### ### ### ### ###
 ### 1- Create cluster 
 "

eksctl create cluster  -f - <<EOF
apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig
metadata:
  name: $CLUSTER
  region: $REGION
  version: "$CLUSTER_VER"

managedNodeGroups:
  - name: mng
    privateNetworking: true
    desiredCapacity: 2
    instanceType: t3.medium
    labels:
      worker: linux
    maxSize: 2
    minSize: 0
    volumeSize: 20
    ssh:
      allow: true
      publicKeyPath: AliSyd

kubernetesNetworkConfig:
  ipFamily: IPv4 # or IPv6

addons:
  - name: vpc-cni
  - name: coredns
  - name: kube-proxy
#  - name: aws-ebs-csi-driver

iam:
  withOIDC: true

iamIdentityMappings:
  - arn: arn:aws:iam::$ACC:user/Ali
    groups:
      - system:masters
    username: admin-Ali
    noDuplicateARNs: true # prevents shadowing of ARNs

cloudWatch:
  clusterLogging:
    enableTypes:
      - "*"

EOF

### ### ### ### ### ### ### ### ### ### ### ### ### ### ### ### ###
echo " ### ### ### ### ### ### ### ### ### ### ### ### ### ### ### ### ###
 ### 2- kubeconfig  : 
 "
aws eks update-kubeconfig --name $CLUSTER --region $REGION


### ### ### ### ### ### ### ### ### ### ### ### ### ### ### ### ###
echo " ### ### ### ### ### ### ### ### ### ### ### ### ### ### ### ### ###
 ### 3- Check cluster node and infrastructure pods  : 
 "
kubectl get node
kubectl -n kube-system get pod 

### ### ### ### ### ### ### ### ### ### ### ### ### ### ### ### ###
echo " ### ### ### ### ### ### ### ### ### ### ### ### ### ### ### ### ###
### 4- Configure access to S3
The driver requires IAM permissions to access your Amazon S3 bucket. 
 We recommend using Mountpoint's suggested IAM permission policy. 
 Alternatively, you can use the AWS managed policy AmazonS3FullAccess, available at ARN arn:aws:iam::aws:policy/AmazonS3FullAccess, 
 but this managed policy grants more permissions than needed for the Mountpoint CSI driver. 
 For more details on creating a policy and an IAM role, review "Creating an IAM policy" and "Creating an IAM role" from the EKS User Guide.
https://github.com/awslabs/mountpoint-s3/blob/main/doc/CONFIGURATION.md#iam-permissions
#### Mountpoint's suggested IAM permission policy >>>>>>>
 "
cat  <<EOF > MountpointFullBucketAccessPolicy.json
{
   "Version": "2012-10-17",
   "Statement": [
        {
            "Sid": "MountpointFullBucketAccess",
            "Effect": "Allow",
            "Action": [
                "s3:ListBucket"
            ],
            "Resource": [
                "arn:aws:s3:::eksbootcampfiles"
            ]
        },
        {
            "Sid": "MountpointFullObjectAccess",
            "Effect": "Allow",
            "Action": [
                "s3:GetObject",
                "s3:PutObject",
                "s3:AbortMultipartUpload",
                "s3:DeleteObject"
            ],
            "Resource": [
                "arn:aws:s3:::eksbootcampfiles/*"
            ]
        }
   ]
}

EOF


### ### ### ### ### ### ### ### ### ### ### ### ### ### ### ### ###
echo " ### ### ### ### ### ### ### ### ### ### ### ### ### ### ### ### ###
 ### 5-  Create policy :
 "

aws iam create-policy \
    --policy-name EKS_S3_CSI_Driver_Policy_eksbootcampfiles \
    --policy-document file://MountpointFullBucketAccessPolicy.json




### ### ### ### ### ### ### ### ### ### ### ### ### ### ### ### ###
echo " ### ### ### ### ### ### ### ### ### ### ### ### ### ### ### ### ###
 ### 6- Secret Object setup :
 NOTE : The CSI driver will read k8s secrets at aws-secret.key_id and aws-secret.access_key to pass keys to the driver. 
 These keys are only read on startup, 
 so must be in place before the driver starts. The following snippet can be used to create these secrets in the cluster:
 "
kubectl create secret generic aws-secret \
    --namespace kube-system \
    --from-literal "key_id=${AWS_ACCESS_KEY_ID}" \
    --from-literal "access_key=${AWS_SECRET_ACCESS_KEY}"

### ### ### ### ### ### ### ### ### ### ### ### ### ### ### ### ###
echo " ### ### ### ### ### ### ### ### ### ### ### ### ### ### ### ### ###
 ### 7- Deploy driver with Helm :
 "
helm repo add aws-mountpoint-s3-csi-driver https://awslabs.github.io/mountpoint-s3-csi-driver
helm repo update
helm upgrade --install aws-mountpoint-s3-csi-driver aws-mountpoint-s3-csi-driver/aws-mountpoint-s3-csi-driver \
--namespace kube-system \
--set controller.serviceAccount.create=false
    


### ### ### ### ### ### ### ### ### ### ### ### ### ### ### ### ###
echo " ### ### ### ### ### ### ### ### ### ### ### ### ### ### ### ### ###
 ### 8-  Create IRSA :
 "

eksctl create iamserviceaccount \
    --name s3-csi-driver-sa \
    --namespace kube-system \
    --cluster $CLUSTER_NAME \
    --attach-policy-arn arn:aws:iam::$ACC:policy/EKS_S3_CSI_Driver_Policy_eksbootcampfiles \
    --approve \
    --region $REGION \
    --override-existing-serviceaccounts

kubectl describe sa s3-csi-driver-sa --namespace kube-system | tee -a s3-csi-driver-sa.yaml
# kubectl annotate  sa s3-csi-driver-sa --namespace kube-system \ 
# eks.amazonaws.com/role-arn=arn:aws:iam::090783120881:role/eksctl-s3-addon-iamserviceaccount-kube-system-Role1-dvbkCaHhV31Y

### ### ### ### ### ### ### ### ### ### ### ### ### ### ### ### ###
echo " ### ### ### ### ### ### ### ### ### ### ### ### ### ### ### ### ###
 ### 9- Once the driver has been deployed, verify the pods are running:
 "
# 
sleep 20 
kubectl -n kube-system get pod -l app.kubernetes.io/name=aws-mountpoint-s3-csi-driver -o wide 
kubectl -n kube-system logs -l app.kubernetes.io/name=aws-mountpoint-s3-csi-driver -c install-mountpoint > log__s3-install-mountpoint_0.log
kubectl -n kube-system logs -l app.kubernetes.io/name=aws-mountpoint-s3-csi-driver -c s3-plugin > log__s3-plugin_1.log
kubectl -n kube-system logs -l app.kubernetes.io/name=aws-mountpoint-s3-csi-driver -c node-driver-registrar > log__s3-node-driver-registrar_1.log
kubectl -n kube-system logs -l app.kubernetes.io/name=aws-mountpoint-s3-csi-driver -c liveness-probe > log__s3-liveness-probe_1.log

### ### ### ### ### ### ### ### ### ### ### ### ### ### ### ### ###
echo " ### ### ### ### ### ### ### ### ### ### ### ### ### ### ### ### ###
 ### 10- Creating pv , pvc , pod , static_provisioning.yaml  :
  "

kubectl apply -f - <<EOF
apiVersion: v1
kind: PersistentVolume
metadata:
  name: s3-pv
spec:
  capacity:
    storage: 1200Gi # ignored, required
  accessModes:
    - ReadWriteMany # supported options: ReadWriteMany / ReadOnlyMany
  mountOptions:
    - allow-delete
    - region ap-southeast-2
  csi:
    driver: s3.csi.aws.com # required
    volumeHandle: s3-csi-driver-volume
    volumeAttributes:
      bucketName: eksbootcampfiles
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: s3-claim
spec:
  accessModes:
    - ReadWriteMany # supported options: ReadWriteMany / ReadOnlyMany
  storageClassName: "" # required for static provisioning
  resources:
    requests:
      storage: 1200Gi # ignored, required
  volumeName: s3-pv
---
apiVersion: v1
kind: Pod
metadata:
  name: s3-app
spec:
  containers:
    - name: app
      image: centos
      command: ["/bin/sh"]
      args: ["-c", "echo 'Hello from the container!' | tee -s /data/$(date +%s).txt; tail -f /dev/null"]
      volumeMounts:
        - name: persistent-storage
          mountPath: /data
  volumes:
    - name: persistent-storage
      persistentVolumeClaim:
        claimName: s3-claim
EOF



### ### ### ### ### ### ### ### ### ### ### ### ### ### ### ### ###
echo " ### ### ### ### ### ### ### ### ### ### ### ### ### ### ### ### ###
### 7- Recording Node , csiNode , SC , PVC , PV , POD  :

"

sleep 60
#kubectl get node -o yaml > node-oyaml.yaml
kubectl describe node  > node-describe.yaml

#kubectl get csinode -o yaml > csinode-oyaml.yaml
kubectl describe csinode > csinode-describe.yaml

#kubectl get csidriver -o yaml > csidriver-oyaml.yaml
kubectl describe csidriver > csidriver-describe.yaml

kubectl get sc -o yaml > sc-oyaml.yaml
kubectl get pv -o yaml > pv-oyaml.yaml
kubectl get pvc -o yaml > pvc-oyaml.yaml
kubectl get pod -o yaml > pod-oyaml.yaml

#kubectl get VolumeAttachment -o yaml > volumeattachment-oyaml.yaml
kubectl describe VolumeAttachment > volumeattachment-describe.yaml


kubectl describe sc > sc-describe.yaml
kubectl describe pv > pv-describe.yaml
kubectl describe pvc > pvc-describe.yaml
kubectl describe pod > pod-describe.yaml

kubectl get event -A > event.txt   

kubectl -n kube-system logs -l app.kubernetes.io/name=aws-mountpoint-s3-csi-driver -c install-mountpoint > log__s3-install-mountpoint_0.log
kubectl -n kube-system logs -l app.kubernetes.io/name=aws-mountpoint-s3-csi-driver -c s3-plugin > log__s3-plugin_2.log
kubectl -n kube-system logs -l app.kubernetes.io/name=aws-mountpoint-s3-csi-driver -c node-driver-registrar > log__s3-node-driver-registrar_2.log
kubectl -n kube-system logs -l app.kubernetes.io/name=aws-mountpoint-s3-csi-driver -c liveness-probe > log__s3-liveness-probe_2.log


