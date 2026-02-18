# Contexto del proyecto — NiFi 2.5.0 en Kubernetes

## Objetivo
Desplegar Apache NiFi 2.5.0 en modo clúster (multi-nodo) sobre Kubernetes con autenticación Single User (usuario + contraseña vía HTTPS).

- **Entorno de desarrollo**: Kubernetes integrado en Docker Desktop (contexto `docker-desktop`)
- **Entorno de producción final**: Kubernetes on-premise (bare metal o VMs)

---

## Estado actual
Los manifiestos están completos y listos para aplicar. Aún no se ha probado el despliegue real; el siguiente paso es ejecutarlo y depurar si hay problemas.

---

## Estructura de ficheros

```
nifi-k8s/
├── CLAUDE.md                  ← este fichero
├── README.md                  ← guía completa de uso
├── kustomization.yaml         ← aplica todo con: kubectl apply -k .
├── 00-namespace.yaml          ← namespace "nifi"
├── 01-zookeeper.yaml          ← ZooKeeper (coordinación del clúster NiFi)
├── 02-nifi-configmap.yaml     ← script de arranque que configura nifi.properties
├── 03-nifi-secret.yaml        ← credenciales: usuario, contraseña, passwords TLS
├── 04-nifi-statefulset.yaml   ← StatefulSet NiFi (2 réplicas por defecto)
└── 05-nifi-services.yaml      ← Headless (descubrimiento) + LoadBalancer (UI)
```

---

## Decisiones de diseño tomadas

### Autenticación
- **Single User Authentication** (NiFi 1.16+, nativo en 2.x)
- Requiere HTTPS obligatoriamente → NiFi autogenera un certificado autofirmado al primer arranque
- Credenciales en `03-nifi-secret.yaml`: usuario `admin`, password `AdminPassword123!` (mín. 12 chars)
- El script en el ConfigMap llama a `set-single-user-credentials.sh` antes de arrancar NiFi

### TLS
- Autofirmado generado por NiFi via `nifi-cert-gen.sh` en el primer arranque
- Keystore/truststore persisten en un PVC dedicado (`nifi-conf`) para sobrevivir reinicios
- Passwords del keystore/truststore también vienen del Secret

### Clúster NiFi
- **StatefulSet** con `serviceName: nifi-headless` → DNS estable por pod:
  `nifi-{0,1}.nifi-headless.nifi.svc.cluster.local`
- `podManagementPolicy: Parallel` → pods arrancan en paralelo
- `publishNotReadyAddresses: true` en el headless service → los nodos se descubren antes de estar Ready
- ZooKeeper externo (1 réplica en local) en `zookeeper.nifi.svc.cluster.local:2181`
- `nifi.cluster.flow.election.max.candidates` = número de réplicas (variable `NIFI_CLUSTER_NODES`)

### Almacenamiento
- Dos PVCs por pod vía `volumeClaimTemplates`:
  - `nifi-data` (5Gi): repositorios de flowfiles, content, provenance, database
  - `nifi-conf` (512Mi): directorio conf con keystore/truststore generados
- StorageClass: default de Docker Desktop (`hostpath`)

### Red
- `nifi-headless` (clusterIP: None): comunicación intra-clúster (puertos 8443, 11443, 10443)
- `nifi-ui` (LoadBalancer): expone `https://localhost:8443/nifi` en Docker Desktop

---

## Comandos frecuentes

```bash
# Desplegar
kubectl apply -k nifi-k8s/

# Estado de pods
kubectl get pods -n nifi -w

# Logs NiFi
kubectl logs -n nifi nifi-0 -f
kubectl logs -n nifi nifi-1 -f

# Logs ZooKeeper
kubectl logs -n nifi zookeeper-0 -f

# Describir pod (eventos, errores)
kubectl describe pod -n nifi nifi-0

# Escalar (actualiza también NIFI_CLUSTER_NODES en el StatefulSet)
kubectl scale statefulset/nifi -n nifi --replicas=3

# Reiniciar pods tras cambio de config
kubectl rollout restart statefulset/nifi -n nifi

# Acceder a shell dentro de un pod
kubectl exec -it -n nifi nifi-0 -- bash

# Limpieza completa
kubectl delete namespace nifi
kubectl delete pvc -n nifi --all
```

---

## Próximos pasos / pendiente

- [ ] Probar el despliegue en Docker Desktop y verificar que el clúster se forma correctamente
- [ ] Validar que la UI es accesible en `https://localhost:8443/nifi`
- [ ] Verificar que ambos nodos aparecen en NiFi UI → menú hamburguesa → Cluster
- [ ] Ajustar recursos (`requests`/`limits`) según la RAM disponible en la máquina de desarrollo
- [ ] Planificar adaptaciones para producción on-premise (ver tabla en README.md)

---

## Notas importantes

- NiFi tarda **3-8 minutos** en arrancar la primera vez (genera TLS + inicializa repositorios)
- Los readinessProbe/livenessProbe tienen tiempos generosos; no tocar hasta validar el arranque
- Si los pods quedan en `Pending`, probablemente Docker Desktop no tiene suficiente RAM → asignar mínimo 8 GB en Docker Desktop > Settings > Resources
- El certificado es autofirmado → el navegador mostrará aviso de seguridad, es normal en desarrollo
- En producción cambiar Single User por LDAP/OIDC y TLS autofirmado por cert-manager