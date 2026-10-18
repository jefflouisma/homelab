#!/bin/bash
set -euo pipefail
export TMPDIR=/Volumes/4TB_Drive/tmp/
namespace=${1:-house}

if kubectl get secret moonlight-server-identity -n "$namespace" >/dev/null 2>&1; then
    echo "Moonlight server identity already exists; keeping it."
    exit 0
fi

kubectl get secret moonlight-tls -n "$namespace" -o json |
    python3 -c 'import json,sys; s=json.load(sys.stdin); json.dump({"apiVersion":"v1","kind":"Secret","metadata":{"name":"moonlight-server-identity","namespace":s["metadata"]["namespace"]},"type":"kubernetes.io/tls","data":{"tls.crt":s["data"]["tls.crt"],"tls.key":s["data"]["tls.key"]}},sys.stdout)' |
    kubectl create -f -
