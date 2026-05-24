# Get into a pod
```bash
kubectl get pods -n <namespace>
kubectl exec -it -n <namespace> <pod-name> -- /bin/bash
```

# Get logs of a pod
```bash
kubectl get pods -n <namespace>
kubectl logs -n <namespace> <pod-name>
```

# Get all resources in a namespace
```bash
kubectl get all -n <namespace>
```
# Get exposed external IPs of a namespace
```bash
kubectl get svc -n <namespace>
```

# Get exposed external IPs of all namespaces
```bash
kubectl get svc -o wide --all-namespaces
```g