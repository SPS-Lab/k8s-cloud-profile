#!/bin/sh

set -x

# Grab our libs
. "`dirname $0`/setup-lib.sh"

if [ -f $OURDIR/kubernetes-extra-done ]; then
    exit 0
fi

logtstart "kubernetes-extra"

maybe_install_packages pssh

# Create a localhost kube-proxy service and fire it off.
cat <<'EOF' | $SUDO tee /etc/systemd/system/kube-proxy.service
[Unit]
Description=Kubernetes Local Proxy Service
After=kubelet.service

[Service]
Type=simple
Restart=always
User=root
ExecStart=/bin/sh -c "kubectl proxy --accept-hosts='.*' --accept-paths='^/api/v1/namespaces/kube-system/services/https:kubernetes-dashboard:/proxy/.*' --address=127.0.0.1 --port=8888"
StandardOutput=journal+console
StandardError=journal+console

[Install]
WantedBy=multi-user.target
EOF
service_init_reload
service_enable kube-proxy
service_start kube-proxy

# Expose the dashboard IFF we have a certificate configuration
if [ ! "$SSLCERTTYPE" = "none" -a "$SSLCERTCONFIG" = "proxy" ]; then
    LCNFQDN=`echo $NFQDN | tr '[:upper:]' '[:lower:]'`
    if [ "$SSLCERTTYPE" = "self" ]; then
	certpath="/etc/ssl/easy-rsa/${NFQDN}.crt"
	keypath="/etc/ssl/easy-rsa/${NFQDN}.key"
    elif [ "$SSLCERTTYPE" = "letsencrypt" ]; then
	certpath="/etc/letsencrypt/live/${LCNFQDN}/fullchain.pem"
	keypath="/etc/letsencrypt/live/${LCNFQDN}/privkey.pem"
    fi
    cat <<EOF | $SUDO tee /etc/nginx/sites-available/k8s-dashboard
map \$http_upgrade \$connection_upgrade {
        default Upgrade;
        ''      close;
}

server {
        listen 8080 ssl;
        listen [::]:8080 ssl;
        ssl_certificate ${certpath};
        ssl_certificate_key ${keypath};
        server_name _;
        location / {
                 proxy_set_header Host \$host;
                 proxy_set_header X-Forwarded-Proto \$scheme;
                 proxy_set_header X-Forwarded-Port \$server_port;
                 proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
                 proxy_set_header X-Real-IP \$remote_addr;
                 proxy_pass http://localhost:8888;
                 proxy_http_version 1.1;
                 proxy_set_header Upgrade \$http_upgrade;
                 proxy_set_header Connection \$connection_upgrade;
                 proxy_read_timeout 900s;
        }
}
EOF
    $SUDO ln -sf /etc/nginx/sites-available/k8s-dashboard \
        /etc/nginx/sites-enabled/k8s-dashboard
    service_restart nginx
fi

# Generate a cluster-wide token for an admin account, and dump it into
# the profile-setup web dir.
kubectl create serviceaccount admin -n default
kubectl create clusterrolebinding cluster-default-admin --clusterrole=cluster-admin --serviceaccount=default:admin
hassecret=`kubectl get serviceaccount admin -n default -o 'jsonpath={.secrets}'`
if [ -n "$hassecret" ]; then
    secretid=`kubectl get serviceaccount admin -n default -o 'go-template={{(index .secrets 0).name}}'`
else
    #
    # Newer kubernetes lacks automatic secrets for serviceaccounts.
    #
    kubectl -n default apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: admin-secret
  annotations:
    kubernetes.io/service-account.name: admin
type: kubernetes.io/service-account-token
EOF
    secretid="admin-secret"
fi
tries=5
while [ $tries -gt 0 ]; do
    token=`kubectl get secrets $secretid -o 'go-template={{.data.token}}' | base64 -d`
    if [ -n "$token" ]; then
	break
    else
	tries=`expr $tries - 1`
	sleep 8
    fi
done
if [ -z "$token" ]; then
    echo "ERROR: failed to get admin token, aborting!"
    exit 1
fi
echo -n "$token" > $OURDIR/admin-token.txt
chmod 644 $OURDIR/admin-token.txt

# Make kubeconfig and token available in profile-setup web dir.
cp -p ~/.kube/config $OURDIR/kubeconfig
chmod 644 $OURDIR/kubeconfig

# Make $SWAPPER a member of the docker group, so that they can do stuff sans sudo.
parallel-ssh -h $OURDIR/pssh.all-nodes sudo usermod -a -G docker $SWAPPER

# If the user wants a local, private, insecure registry on $HEAD $MGMTLAN, set that up.
if [ "$DOLOCALREGISTRY" = "1" ]; then
    ip=`getnodeip $HEAD $MGMTLAN`
    $SUDO docker create --restart=always -p $ip:5000:5000 --name local-registry registry:2
    $SUDO docker start local-registry
fi

# If the user wanted NFS, make a dynamic nfs subdir provisioner the default
# storageclass.
if [ -n "$DONFS" -a "$DONFS" = "1" ]; then
    NFSSERVERIP=`getnodeip $HEAD $DATALAN`
    helm repo add nfs-subdir-external-provisioner \
        https://kubernetes-sigs.github.io/nfs-subdir-external-provisioner/
    helm repo update
    cat <<EOF >$OURDIR/nfs-provisioner-values.yaml
nfs:
  server: "$NFSSERVERIP"
  path: $NFSEXPORTDIR
  mountOptions:
    - "nfsvers=3"
storageClass:
  defaultClass: true
EOF
    helm install nfs-subdir-external-provisioner \
        nfs-subdir-external-provisioner/nfs-subdir-external-provisioner \
	-f $OURDIR/nfs-provisioner-values.yaml --wait
fi

# Installs volcano
wget https://github.com/volcano-sh/volcano/archive/refs/tags/v1.8.0.tar.gz
tar xvf v1.8.0.tar.gz 
kubectl create -f volcano-1.8.0/installer/volcano-development.yaml 
kubectl wait pod -n volcano-system --for=condition=Ready --all

# Installs influxdb
git clone https://github.com/raijenki/kubv2.git
helm repo add influxdata https://helm.influxdata.com/
helm upgrade --install opencube influxdata/influxdb -f $OURDIR/kubv2/schemon/values.yaml
kubectl wait pod -n default opencube-influxdb-0 --for=condition=Ready --all
sleep 180
kubectl get svc opencube-influxdb -o jsonpath='{.spec.clusterIP}' > $OURDIR/influxdb-ip.txt
INFLUXIP=$(cat $OURDIR/influxdb-ip.txt)
NODE=1
while [ $NODE -lt $NODECOUNT ]
do  
    DATABASE_NAME="node$NODE"
    ssh node-$NODE "git clone https://github.com/raijenki/kubv2.git && cd kubv2/schemon/ && make && ./njmon_Ubuntu22_aarch64_v81 -I -f -s 30 -i $INFLUXIP -p 8086 -x node$NODE -y admin -z 123456 && exit"
    kubectl exec -it opencube-influxdb-0 -- influx -execute "CREATE DATABASE $DATABASE_NAME"
    NODE=$(expr $NODE + 1) 
    sleep 2
done

#kubectl apply -f https://raw.githubusercontent.com/longhorn/longhorn/v1.5.1/deploy/longhorn.yaml
#kubectl wait pod -n longhorn-system --for=condition=Ready --all

logtend "kubernetes-extra"
touch $OURDIR/kubernetes-extra-done
exit 0
