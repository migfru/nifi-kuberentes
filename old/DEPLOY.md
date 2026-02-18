# NiFi cluster deployment (sin Keycloak)

## Archivos
- Base: `nifi.yaml`
- Override on-prem: `overrides/onprem.yaml`
- TLS helper: `setup-tls.ps1`

## 1) TLS secret `nifi-tls`
NiFi en este despliegue usa HTTPS y cluster protocol seguro, por lo que el secret `nifi-tls` es obligatorio.

### Local (Docker Desktop Kubernetes + nip.io)
1. Crear/actualizar certificados y secret:
   - `powershell -ExecutionPolicy Bypass -File .\\setup-tls.ps1 -Namespace nifi -SecretName nifi-tls -ClusterDomain cluster.local -AdditionalDnsNames nifi.127.0.0.1.nip.io`
2. Verificar secret:
   - `kubectl -n nifi get secret nifi-tls`

### On-prem (cliente)
1. Ajustar SAN/FQDN en `setup-tls.ps1`:
   - agregar DNS reales del Ingress y servicios internos (`*.nifi-headless.<ns>.svc.<clusterDomain>`, `nifi.<dominio-cliente>`).
2. Generar y aplicar secret:
   - `powershell -ExecutionPolicy Bypass -File .\\setup-tls.ps1 -Namespace nifi -SecretName nifi-tls -ClusterDomain <cluster-domain-real>`
3. Rotacion de certificados:
   - regenerar `nifi-tls` con el script.
   - reiniciar StatefulSet para forzar recarga limpia:
   - `kubectl -n nifi rollout restart statefulset nifi`
   - `kubectl -n nifi rollout status statefulset nifi`

## 2) Despliegue
### Local
1. `kubectl apply -f .\\nifi.yaml`

### On-prem
1. Editar `overrides/onprem.yaml` con el FQDN real del cliente.
2. Aplicar base + override:
   - `kubectl apply -f .\\nifi.yaml -f .\\overrides\\onprem.yaml`

## 3) Credenciales single-user
Se toman desde secret `nifi-auth` en `nifi.yaml`:
- `single-user-username`
- `single-user-password`

Cambiar estos valores antes de ambientes compartidos/productivos.

## 4) Checklist de validacion
### Base (ambos entornos)
- `kubectl -n nifi get pods` muestra `zk-0`, `nifi-0`, `nifi-1` en `Running`.
- `kubectl -n nifi get pvc` muestra todos los PVC en `Bound`.
- `kubectl -n nifi get svc` muestra `nifi`, `nifi-headless`, `zk`.
- `kubectl -n nifi get ingress nifi` resuelve al host esperado.
- `kubectl -n nifi logs nifi-0` sin errores de keystore/truststore/zookeeper.

### Funcional
- UI abre por HTTPS en el host configurado.
- Login con `single-user-username`/`single-user-password`.
- En UI se observan 2 nodos del cluster conectados.

### On-prem adicional
- Certificado presentado por Ingress coincide con dominio real.
- DNS corporativo resuelve el host de NiFi.
- Prueba de reinicio controlado: `rollout restart` y nodos vuelven `Ready`.
