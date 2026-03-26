# WAA Platform Starter

Pachet de pornire pentru:
- HAProxy
- k3s manifests pentru un API generic
- Cloudflare Tunnel în Kubernetes
- documentația playbook

Înlocuiește valorile placeholder:
- `api.example.com`
- `ghcr.io/example/app-api:latest`
- `CHANGE_ME`
- `TUNNEL_ID`

Aplicare recomandată:
```bash
kubectl apply -f kubernetes/infra/cloudflared/namespace.yaml
kubectl apply -f kubernetes/app/namespace.yaml
kubectl apply -f kubernetes/app/
```
