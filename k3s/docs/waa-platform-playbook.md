# WAA Platform Playbook
## Proxmox + Ubuntu + k3s + Cloudflare Tunnel + PostgreSQL

> Document de lucru pentru o infrastructură scalabilă, sigură și ușor de extins, construită în jurul unui cluster k3s, baze de date PostgreSQL separate și expunere publică prin Cloudflare Tunnel.

---

## 1. Scop

Acest document descrie o arhitectură recomandată pentru rularea unuia sau mai multor backend-uri API într-un mediu virtualizat Proxmox, cu următoarele obiective:

- update-uri fără downtime perceptibil
- separare clară între aplicații
- bază de date în afara clusterului Kubernetes
- securitate bună prin eliminarea expunerii directe în internet
- posibilitate de migrare ulterioară pe alt host/VPS
- fundație bună pentru CI/CD și extindere viitoare

Pentru simplitate, în exemple vom folosi un nume generic:

- namespace Kubernetes: `app`
- host public: `api.example.com`
- deployment: `app-api`

---

## 2. Arhitectura generală

```text
[ Internet ]
     |
[ Cloudflare ]
     |
[ Cloudflare Tunnel ]
     |
[ Kubernetes Cluster (k3s) ]
     |
[ Traefik Ingress ]
     |
[ Service ]
     |
[ Deployment / Pods ]
     |
[ PostgreSQL VM ]
```

### Principii cheie

- traficul public intră doar prin Cloudflare Tunnel
- aplicațiile rulează în Kubernetes
- PostgreSQL rulează pe un VM separat
- clusterul k3s are 3 server nodes
- API-urile importante rulează în minimum 2 replici
- actualizările se fac prin rolling updates

---

## 3. Topologia VM-urilor

### 3.1 VM-uri necesare

| VM Name | Rol | IP recomandat |
|---|---|---|
| `db-prod-01` | PostgreSQL | `10.10.10.10` |
| `k3s-lb-01` | Load balancer pentru API-ul Kubernetes | `10.10.10.20` |
| `k3s-srv-01` | K3s server node | `10.10.10.21` |
| `k3s-srv-02` | K3s server node | `10.10.10.22` |
| `k3s-srv-03` | K3s server node | `10.10.10.23` |

### 3.2 Resurse recomandate

#### `db-prod-01`
- 4 vCPU
- 16 GB RAM
- 250 GB disk

#### `k3s-lb-01`
- 1 vCPU
- 2 GB RAM
- 20 GB disk

#### `k3s-srv-01`
- 4 vCPU
- 12 GB RAM
- 100 GB disk

#### `k3s-srv-02`
- 4 vCPU
- 12 GB RAM
- 100 GB disk

#### `k3s-srv-03`
- 4 vCPU
- 12 GB RAM
- 100 GB disk

### 3.3 Consum total estimat

- 17 vCPU
- 54 GB RAM
- ~570 GB storage alocat

Această topologie este potrivită atât pentru un lab serios, cât și pentru un mediu mic spre mediu, orientat spre producție.

---

## 4. Design de rețea

### 4.1 Subnet intern

Exemplu:

- `10.10.10.0/24`

### 4.2 Reguli

- toate VM-urile folosesc IP static
- PostgreSQL nu este expus public
- API-urile nu sunt expuse direct public
- accesul public vine doar prin Cloudflare Tunnel
- SSH permis doar pe cheie și, ideal, restricționat pe IP-urile tale

### 4.3 Rezolvare nume

Poți folosi temporar `/etc/hosts` sau DNS intern:

- `db-prod-01.lab.local`
- `k3s-lb-01.lab.local`
- `k3s-srv-01.lab.local`
- `k3s-srv-02.lab.local`
- `k3s-srv-03.lab.local`

---

## 5. Rolul fiecărei componente

### 5.1 PostgreSQL pe VM separat

Baza de date nu rulează în Kubernetes în prima etapă.

#### De ce
- backup mai simplu
- restore mai simplu
- tuning mai simplu
- mai puțină complexitate operațională
- separare clară între compute și storage

#### Recomandare logică
Folosește baze separate și useri separați pentru fiecare aplicație, chiar dacă motorul PostgreSQL este unic.

Exemplu:

- database: `app_db`
- user: `app_user`

---

### 5.2 k3s Cluster

Clusterul are 3 server nodes.

#### De ce 3 server nodes
- embedded etcd cu quorum
- bază corectă pentru HA
- rolling updates curate
- toleranță mai bună la incidente sau mentenanță

#### Observație
La început, aceste noduri pot rula și workload-uri. Nu este nevoie să separi control plane și worker din prima zi.

---

### 5.3 Load Balancer pentru Kubernetes API

VM-ul `k3s-lb-01` există pentru a oferi o adresă fixă pentru API-ul clusterului:

- `10.10.10.20:6443`

Acest load balancer va trimite traficul către:

- `10.10.10.21:6443`
- `10.10.10.22:6443`
- `10.10.10.23:6443`

Avantaje:
- adresă unică de join pentru cluster
- administrare mai curată
- extindere mai simplă

---

### 5.4 Traefik Ingress

Traefik este ingress controller-ul implicit din k3s și este suficient pentru prima etapă.

#### Rol
- primește traficul HTTP/HTTPS din cluster
- face rutare pe hostname/path
- trimite traficul către Service-ul potrivit

---

### 5.5 Cloudflare Tunnel

Cloudflare Tunnel va fi punctul de expunere publică.

#### Flux
```text
Cloudflare -> Tunnel -> Traefik -> Service -> Pods
```

#### Avantaje
- fără IP public expus pentru origin
- mutare mai ușoară pe alt server
- integrare bună cu restul ecosistemului Cloudflare
- posibilitate de protecție suplimentară pentru endpoint-uri interne

---

## 6. Structura Kubernetes recomandată

### 6.1 Namespace-uri

Pentru exemplul generic:

- `infra`
- `app`

#### `infra`
Conține componente comune de infrastructură:
- `cloudflared`
- ulterior, opțional: monitoring, logging, alte servicii comune

#### `app`
Conține API-ul generic:
- Deployment
- Service
- Ingress
- ConfigMap
- Secret

---

### 6.2 Structură logică

```text
Cluster
├── namespace: infra
│   └── cloudflared
│
└── namespace: app
    ├── Deployment
    ├── Service
    ├── Ingress
    ├── ConfigMap
    └── Secret
```

---

## 7. Principii pentru no downtime

No downtime credibil vine din combinarea mai multor elemente:

- minimum 2 replici
- readiness probe
- rolling update strategy
- aplicație care pornește corect și rapid
- shutdown elegant
- migrații de DB compatibile cu versiunea anterioară, când este necesar

### Regula de bază
Nu actualiza un API critic cu o singură replică dacă vrei disponibilitate bună.

### Recomandare
Pentru API-ul principal:

- `replicas: 2`
- `maxUnavailable: 0`
- `maxSurge: 1`

---

## 8. Ordinea de implementare

### Etapa 1 — Creare VM-uri în Proxmox

Creezi următoarele VM-uri:

- `db-prod-01`
- `k3s-lb-01`
- `k3s-srv-01`
- `k3s-srv-02`
- `k3s-srv-03`

#### Setări recomandate
- Ubuntu Server LTS
- VirtIO pentru disk și network
- QEMU Guest Agent activ
- IP static
- hostname corect
- actualizări făcute imediat după instalare

---

### Etapa 2 — Hardening minim pe toate VM-urile

Pe fiecare VM:

- creezi user non-root cu sudo
- instalezi cheia SSH
- dezactivezi autentificarea cu parolă pentru root
- setezi timezone
- instalezi `qemu-guest-agent`
- faci `apt update && apt upgrade`

#### Pachete utile
```bash
sudo apt update && sudo apt upgrade -y
sudo apt install -y qemu-guest-agent curl wget vim ufw ca-certificates apt-transport-https gnupg lsb-release
sudo systemctl enable --now qemu-guest-agent
```

---

### Etapa 3 — Configurare firewall minim

#### `db-prod-01`
Permite:
- SSH
- PostgreSQL doar din subnet-ul intern sau din nodurile K3s

Exemplu:
```bash
sudo ufw allow OpenSSH
sudo ufw allow from 10.10.10.0/24 to any port 5432 proto tcp
sudo ufw enable
```

#### `k3s-lb-01`
Permite:
- SSH
- 6443 către nodurile interne dacă ai nevoie de test local

#### nodurile K3s
Permite:
- SSH
- trafic intern necesar clusterului
- evită expunerea inutilă spre internet

> Notă: în practică, regulile exacte pentru k3s pot fi ajustate după instalare și testare. Pentru prima etapă, concentrează-te pe a nu expune public porturi inutile.

---

### Etapa 4 — Instalare PostgreSQL pe `db-prod-01`

#### Pachete
```bash
sudo apt install -y postgresql postgresql-contrib
```

#### Pornire și activare
```bash
sudo systemctl enable --now postgresql
```

#### Exemple de baze și user
```sql
CREATE DATABASE app_db;
CREATE USER app_user WITH ENCRYPTED PASSWORD 'SCHIMBA_PAROLA';
GRANT ALL PRIVILEGES ON DATABASE app_db TO app_user;
```

#### Recomandări PostgreSQL
- ascultă doar pe IP intern
- configurează `pg_hba.conf` doar pentru acces intern
- folosește backup zilnic
- nu expune 5432 public

---

### Etapa 5 — Instalare HAProxy pe `k3s-lb-01`

#### Instalare
```bash
sudo apt install -y haproxy
```

#### Config exemplu
Fișier: `/etc/haproxy/haproxy.cfg`

```cfg
global
    log /dev/log local0
    log /dev/log local1 notice
    daemon

defaults
    log global
    mode tcp
    timeout connect 10s
    timeout client  1m
    timeout server  1m

frontend k3s_api
    bind 10.10.10.20:6443
    default_backend k3s_api_backend

backend k3s_api_backend
    balance roundrobin
    option tcp-check
    server k3s-srv-01 10.10.10.21:6443 check
    server k3s-srv-02 10.10.10.22:6443 check
    server k3s-srv-03 10.10.10.23:6443 check
```

#### Activare
```bash
sudo systemctl restart haproxy
sudo systemctl enable haproxy
```

#### Test
```bash
nc -vz 10.10.10.20 6443
```

---

### Etapa 6 — Instalare k3s HA

#### 6.1 Pe primul nod: `k3s-srv-01`

```bash
curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="server --cluster-init --tls-san 10.10.10.20" sh -
```

#### Verificare
```bash
sudo kubectl get nodes
```

#### Token de join
```bash
sudo cat /var/lib/rancher/k3s/server/node-token
```

Salvează token-ul.

---

#### 6.2 Pe `k3s-srv-02` și `k3s-srv-03`

Înlocuiește `TOKEN_AICI` cu token-ul real.

```bash
curl -sfL https://get.k3s.io | K3S_URL=https://10.10.10.20:6443 K3S_TOKEN=TOKEN_AICI sh -s - server
```

#### Verificare finală
Pe `k3s-srv-01`:

```bash
sudo kubectl get nodes
```

Ar trebui să vezi toate cele 3 noduri în starea `Ready`.

---

### Etapa 7 — Acces administrativ la cluster

Pe `k3s-srv-01`:

```bash
sudo cat /etc/rancher/k3s/k3s.yaml
```

Copiază fișierul local și înlocuiește în el IP-ul `127.0.0.1` sau hostname-ul local cu:

- `10.10.10.20`

Apoi pe mașina ta locală:

```bash
export KUBECONFIG=~/kubeconfigs/app-lab.yaml
kubectl get nodes
```

---

### Etapa 8 — Namespace-uri

```bash
kubectl create namespace infra
kubectl create namespace app
```

Verificare:

```bash
kubectl get ns
```

---

### Etapa 9 — Primul Deployment generic

Mai jos este un exemplu minimal pentru un API generic.

Fișier: `app-api-deployment.yaml`

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: app-api
  namespace: app
spec:
  replicas: 2
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxUnavailable: 0
      maxSurge: 1
  selector:
    matchLabels:
      app: app-api
  template:
    metadata:
      labels:
        app: app-api
    spec:
      containers:
        - name: app-api
          image: ghcr.io/example/app-api:latest
          imagePullPolicy: Always
          ports:
            - containerPort: 8080
          env:
            - name: ASPNETCORE_URLS
              value: http://+:8080
          readinessProbe:
            httpGet:
              path: /health/ready
              port: 8080
            initialDelaySeconds: 10
            periodSeconds: 5
          livenessProbe:
            httpGet:
              path: /health/live
              port: 8080
            initialDelaySeconds: 20
            periodSeconds: 10
```

Aplicare:

```bash
kubectl apply -f app-api-deployment.yaml
```

---

### Etapa 10 — Service

Fișier: `app-api-service.yaml`

```yaml
apiVersion: v1
kind: Service
metadata:
  name: app-api
  namespace: app
spec:
  type: ClusterIP
  selector:
    app: app-api
  ports:
    - port: 80
      targetPort: 8080
```

Aplicare:

```bash
kubectl apply -f app-api-service.yaml
```

---

### Etapa 11 — Ingress

Fișier: `app-api-ingress.yaml`

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: app-api
  namespace: app
spec:
  ingressClassName: traefik
  rules:
    - host: api.example.com
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: app-api
                port:
                  number: 80
```

Aplicare:

```bash
kubectl apply -f app-api-ingress.yaml
```

Verificare:

```bash
kubectl get ingress -n app
```

---

### Etapa 12 — Secret pentru stringul de conexiune

Fișier: `app-api-secret.yaml`

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: app-api-secrets
  namespace: app
type: Opaque
stringData:
  ConnectionStrings__Default: Host=10.10.10.10;Port=5432;Database=app_db;Username=app_user;Password=SCHIMBA_PAROLA
```

Aplicare:

```bash
kubectl apply -f app-api-secret.yaml
```

Apoi în Deployment:

```yaml
env:
  - name: ConnectionStrings__Default
    valueFrom:
      secretKeyRef:
        name: app-api-secrets
        key: ConnectionStrings__Default
```

---

### Etapa 13 — Cloudflare Tunnel în Kubernetes

#### Abordare recomandată
- creezi tunelul în Cloudflare
- păstrezi credentials ca Secret în namespace `infra`
- rulezi `cloudflared` ca Deployment

#### Flux
```text
Cloudflare -> cloudflared -> Traefik -> app-api Service -> Pods
```

#### Config logic
- `api.example.com` -> `http://traefik.kube-system.svc.cluster.local:80`
- Traefik se ocupă mai departe de Ingress și Service

> Implementarea exactă a `cloudflared` poate varia în funcție de modul în care vrei să gestionezi credentials și tunelul. Important este să păstrezi tunelul în `infra` și să îl separi de aplicație.

---

### Etapa 14 — Comenzi utile de operare

#### Noduri
```bash
kubectl get nodes -o wide
```

#### Poduri
```bash
kubectl get pods -A
kubectl get pods -n app
```

#### Deployment
```bash
kubectl get deploy -n app
kubectl describe deploy app-api -n app
```

#### Service
```bash
kubectl get svc -n app
```

#### Ingress
```bash
kubectl get ingress -n app
kubectl describe ingress app-api -n app
```

#### Logs
```bash
kubectl logs -n app deploy/app-api
```

#### Rollout status
```bash
kubectl rollout status deployment/app-api -n app
```

#### Restart deployment
```bash
kubectl rollout restart deployment/app-api -n app
```

#### Istoric rollout
```bash
kubectl rollout history deployment/app-api -n app
```

#### Rollback
```bash
kubectl rollout undo deployment/app-api -n app
```

---

### Etapa 15 — Test de update fără downtime

#### Pași
1. publici o imagine nouă
2. actualizezi tag-ul imaginii
3. aplici Deployment-ul nou
4. urmărești rollout-ul

Exemplu:
```bash
kubectl set image deployment/app-api app-api=ghcr.io/example/app-api:v2 -n app
kubectl rollout status deployment/app-api -n app
```

#### Ce vrei să vezi
- pod nou pornit
- readiness probe trecută
- pod vechi oprit abia după ce cel nou devine `Ready`

---

## 16. Structură recomandată de fișiere Git

```text
infra/
├── README.md
├── haproxy/
│   └── haproxy.cfg
├── kubernetes/
│   ├── infra/
│   │   └── cloudflared/
│   └── app/
│       ├── namespace.yaml
│       ├── deployment.yaml
│       ├── service.yaml
│       ├── ingress.yaml
│       └── secret.example.yaml
└── docs/
    └── waa-platform-playbook.md
```

---

## 17. Checklist de implementare

### Proxmox / VM-uri
- [ ] VM-urile au fost create
- [ ] IP-urile sunt statice
- [ ] Hostname-urile sunt setate corect
- [ ] `qemu-guest-agent` este instalat

### Sistem de operare
- [ ] update și upgrade efectuate
- [ ] user non-root cu sudo
- [ ] SSH pe cheie
- [ ] UFW activ unde este cazul

### PostgreSQL
- [ ] PostgreSQL instalat
- [ ] database creată
- [ ] user creat
- [ ] acces permis doar intern
- [ ] backup planificat

### HAProxy
- [ ] HAProxy instalat
- [ ] config validă
- [ ] portul 6443 răspunde pe LB

### k3s
- [ ] primul server inițializat
- [ ] nodurile 2 și 3 atașate
- [ ] toate nodurile sunt `Ready`
- [ ] kubeconfig funcțional local

### Kubernetes app
- [ ] namespace `infra` creat
- [ ] namespace `app` creat
- [ ] Deployment aplicat
- [ ] Service aplicat
- [ ] Ingress aplicat
- [ ] Secret aplicat
- [ ] rollout testat

### Cloudflare
- [ ] Tunnel creat
- [ ] `cloudflared` deployat
- [ ] hostname-ul public rutează spre ingress

---

## 18. Ce nu facem încă

Pentru prima iterație, evităm:

- PostgreSQL în Kubernetes
- storage distribuit
- autoscaling avansat
- ArgoCD / GitOps
- Prometheus, Loki, Grafana toate din prima
- cert-manager, dacă nu ai o nevoie clară imediată

Ținta este:
- cluster stabil
- API funcțional
- conectare la DB extern
- update-uri curate
- operațiuni simple

---

## 19. Riscuri și observații

### 1. Kubernetes nu rezolvă singur tot
Dacă aplicația nu are health checks bune sau nu se oprește elegant, no downtime-ul va avea de suferit.

### 2. Migrațiile DB trebuie gândite atent
Unele schimbări de schemă pot rupe compatibilitatea dintre versiunea veche și cea nouă.

### 3. 3 server nodes ajută clusterul, nu înlocuiesc backup-ul
Trebuie să ai:
- backup pentru DB
- backup pentru config-uri
- eventual snapshot-uri Proxmox înainte de schimbări mari

---

## 20. Următorii pași recomandați

După ce acest setup funcționează, următoarele îmbunătățiri sănătoase sunt:

1. pipeline de build și publish imagini
2. versionare clară a deployment-urilor
3. backup automat PostgreSQL
4. monitoring de bază
5. politici anti-affinity
6. PodDisruptionBudget pentru workload-urile importante

---

## 21. Concluzie

Această arhitectură oferă o bază foarte bună pentru:

- backend-uri containerizate
- update-uri curate
- disponibilitate bună
- izolare între aplicații
- expunere sigură prin Cloudflare
- extindere ulterioară fără refactor major

Pe scurt:

- Proxmox pentru virtualizare
- Ubuntu pe toate VM-urile
- 1 VM PostgreSQL separat
- 1 VM HAProxy pentru API-ul K8s
- 3 noduri k3s server
- Traefik ca ingress
- Cloudflare Tunnel pentru acces public
- namespace generic `app`
- API generic `app-api`
- minimum 2 replici pentru workload-ul important

---

## 22. Anexă — Comenzi rapide

### Instalează pachete de bază
```bash
sudo apt update && sudo apt upgrade -y
sudo apt install -y qemu-guest-agent curl wget vim ufw ca-certificates apt-transport-https gnupg lsb-release
sudo systemctl enable --now qemu-guest-agent
```

### Verifică noduri
```bash
kubectl get nodes -o wide
```

### Verifică toate resursele din namespace
```bash
kubectl get all -n app
```

### Urmărește rollout
```bash
kubectl rollout status deployment/app-api -n app
```

### Fă rollback
```bash
kubectl rollout undo deployment/app-api -n app
```

### Verifică logs
```bash
kubectl logs -n app deploy/app-api
```
