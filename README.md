# Apache NiFi 2.5.0 en Kubernetes — Guía de despliegue

## Descripción

Este repositorio contiene los manifiestos Kubernetes para desplegar **Apache NiFi 2.5.0 en modo clúster** (multi-nodo) sobre cualquier clúster Kubernetes.

NiFi es una plataforma de integración de datos que permite diseñar, controlar y monitorizar flujos de datos entre sistemas mediante una interfaz visual basada en web. El despliegue proporciona:

- **Alta disponibilidad**: 2 nodos NiFi activos (ampliable) coordinados vía ZooKeeper.
- **Persistencia**: cada nodo mantiene sus repositorios de datos en volúmenes persistentes independientes.
- **Seguridad**: comunicación HTTPS en todos los endpoints (UI, API, intra-clúster y Site-to-Site), autenticación mediante usuario y contraseña.
- **Gestión centralizada del flujo**: un único flujo de datos replicado en todos los nodos del clúster.

---

## Arquitectura

```
                        ┌─────────────────────────────────┐
                        │         Namespace: nifi          │
                        │                                  │
  Usuario / Cliente     │   ┌──────────┐  ┌──────────┐   │
  ──────────────────►   │   │  nifi-0  │  │  nifi-1  │   │
  https://<ip>:8443     │   │  :8443   │  │  :8443   │   │
                        │   │  :11443  │  │  :11443  │   │
  Service: nifi-ui      │   │  :10443  │  │  :10443  │   │
  (LoadBalancer /       │   └────┬─────┘  └─────┬────┘   │
   NodePort / Ingress)  │        │               │        │
                        │        └───────┬───────┘        │
                        │    nifi-headless (DNS interno)   │
                        │                │                │
                        │        ┌───────▼───────┐        │
                        │        │  zookeeper-0  │        │
                        │        │    :2181      │        │
                        │        └───────────────┘        │
                        └─────────────────────────────────┘
```

**Componentes:**

| Recurso | Tipo Kubernetes | Descripción |
|---|---|---|
| `nifi` | StatefulSet | 2 pods NiFi con identidad DNS estable (`nifi-0`, `nifi-1`, …) |
| `nifi-headless` | Service (Headless) | DNS interno para comunicación entre nodos del clúster |
| `nifi-ui` | Service (LoadBalancer) | Expone la UI y la API al exterior |
| `zookeeper` | StatefulSet | Coordinación del clúster NiFi y elección de líder |
| `nifi-config` | ConfigMap | Script de arranque que configura cada nodo con su identidad |
| `nifi-credentials` | Secret | Credenciales de usuario y clave de cifrado del flujo |
| `nifi-tls` | Secret | Certificados keystore/truststore compartidos por todos los nodos |

---

## Estructura de ficheros

```
.
├── README.md                   ← este documento
├── kustomization.yaml          ← punto de entrada: kubectl apply -k .
├── setup-tls.ps1          ← genera los certificados TLS compartidos
├── tls/
│   ├── keystore.p12            ← keystore PKCS12 compartido (generado por setup-tls.ps1)
│   ├── truststore.p12          ← truststore PKCS12 compartido
│   └── nifi.crt               ← certificado público exportado
├── 00-namespace.yaml           ← namespace "nifi"
├── 01-zookeeper.yaml           ← ZooKeeper (coordinación del clúster)
├── 02-nifi-configmap.yaml      ← script de arranque y configuración por nodo
├── 03-nifi-secret.yaml         ← credenciales de usuario y clave de cifrado
├── 04-nifi-statefulset.yaml    ← StatefulSet NiFi (réplicas, recursos, volúmenes)
└── 05-nifi-services.yaml       ← servicios de red (headless + exposición UI)
```

---

## Prerrequisitos

- Clúster Kubernetes operativo (versión ≥ 1.25)
- `kubectl` configurado con acceso al clúster objetivo
- `docker` disponible en la máquina local (para generar los certificados TLS en el Paso 1)
- PowerShell (Windows) o PowerShell Core (Linux/macOS) para ejecutar `setup-tls.ps1`
- StorageClass disponible en el clúster con modo de acceso `ReadWriteOnce`

---

## Pasos de despliegue

### Paso 1 — Generar los certificados TLS

NiFi requiere HTTPS obligatoriamente. El script `setup-tls.ps1` genera un **certificado wildcard compartido** por todos los nodos del clúster.

El certificado cubre automáticamente todos los pods del StatefulSet gracias al SAN `*.nifi-headless.nifi.svc.cluster.local`.

Ejecutar desde la raíz del repositorio:

```powershell
.\old\setup-tls.ps1 `
    -Namespace     "nifi" `
    -StorePassword "TuPasswordSegura123!" `
    -ClusterDomain "cluster.local"
```

El script:
1. Genera un par de claves RSA 4096-bit con validez 10 años usando la imagen Docker `eclipse-temurin:21-jdk`.
2. Crea `tls/keystore.p12` y `tls/truststore.p12`.
3. Crea o actualiza el Secret `nifi-tls` en Kubernetes con los ficheros binarios y las contraseñas.

**Parámetros del script:**

| Parámetro | Valor por defecto | Descripción | Cambiar si… |
|---|---|---|---|
| `-Namespace` | `nifi` | Namespace de Kubernetes donde se despliega | Se usa un namespace distinto |
| `-StorePassword` | `nifi1234` | Contraseña del keystore y truststore | **Siempre** — usar valor seguro |
| `-ClusterDomain` | `cluster.local` | Dominio DNS interno del clúster | El clúster usa un dominio diferente |
| `-AdditionalDnsNames` | `@()` | SANs adicionales (array de strings) | Se accede con un FQDN externo (p.ej. Ingress) |
| `-SkipSecret` | `$false` | Solo genera ficheros, sin crear el Secret | Se gestiona el Secret manualmente |

Ejemplo con SANs adicionales para un Ingress:
```powershell
.\old\setup-tls.ps1 `
    -StorePassword     "TuPasswordSegura123!" `
    -AdditionalDnsNames @("nifi.miempresa.com", "nifi-api.miempresa.com")
```

---

### Paso 2 — Configurar credenciales (`03-nifi-secret.yaml`)

Editar [03-nifi-secret.yaml](03-nifi-secret.yaml). Todos los valores deben estar en **Base64**.

Para codificar un valor en Base64:
```bash
echo -n 'MiValorSecreto' | base64
```

**Variables obligatorias:**

| Clave en el Secret | Descripción | Requisitos |
|---|---|---|
| `NIFI_USERNAME` | Usuario administrador de NiFi | Cualquier nombre de usuario |
| `NIFI_PASSWORD` | Contraseña del usuario administrador | **Mínimo 12 caracteres** (requisito de NiFi 2.x) |
| `NIFI_SENSITIVE_PROPS_KEY` | Clave de cifrado de propiedades sensibles del flujo. Protege passwords y credenciales almacenadas en el diseño de flujos. | **Mínimo 12 caracteres. Debe ser idéntica en todos los nodos.** |

> `KEYSTORE_PASSWORD` y `TRUSTSTORE_PASSWORD` **no** se configuran aquí. El Paso 1 las gestiona automáticamente en el Secret `nifi-tls`.

Ejemplo de edición completa:
```bash
# Generar los valores
echo -n 'operador'                  | base64   # → NIFI_USERNAME
echo -n 'Passw0rd.Prod.2024!'       | base64   # → NIFI_PASSWORD
echo -n 'ClaveFlujoProd.Segura24!'  | base64   # → NIFI_SENSITIVE_PROPS_KEY
```

Sustituir las líneas correspondientes en el fichero:
```yaml
data:
  NIFI_USERNAME:            <base64 del usuario>
  NIFI_PASSWORD:            <base64 de la contraseña>
  NIFI_SENSITIVE_PROPS_KEY: <base64 de la clave de cifrado>
```

---

### Paso 3 — Ajustar nodos y recursos (`04-nifi-statefulset.yaml`)

Editar [04-nifi-statefulset.yaml](04-nifi-statefulset.yaml).

**Número de nodos:**

```yaml
spec:
  replicas: 2          # ← número de nodos NiFi

  ...
  env:
    - name: NIFI_CLUSTER_NODES
      value: "2"       # ← debe ser igual a replicas
```

> Ambos valores deben ser el mismo número. Si se cambia uno, cambiar el otro.

**Recursos por pod:**

```yaml
resources:
  requests:
    memory: "2Gi"      # RAM mínima garantizada por pod (mínimo para arrancar)
    cpu: "500m"        # CPU mínima garantizada
  limits:
    memory: "4Gi"      # RAM máxima por pod
    cpu: "2000m"       # CPU máxima (2 cores)
```

Recomendaciones por entorno:

| Entorno | `requests.memory` | `limits.memory` | `requests.cpu` | `limits.cpu` |
|---|---|---|---|---|
| Desarrollo / pruebas | `2Gi` | `4Gi` | `500m` | `2000m` |
| Producción ligera | `4Gi` | `8Gi` | `1000m` | `4000m` |
| Producción con carga alta | `8Gi` | `16Gi` | `2000m` | `8000m` |

---

### Paso 4 — Configurar almacenamiento (`04-nifi-statefulset.yaml`)

Al final del fichero, `volumeClaimTemplates` define los PVCs que Kubernetes creará automáticamente para cada pod.

```yaml
volumeClaimTemplates:
  - metadata:
      name: nifi-data        # repositorios de datos (flowfiles, content, provenance, database)
    spec:
      accessModes: ["ReadWriteOnce"]
      storageClassName: ""   # ← nombre de la StorageClass del clúster
      resources:
        requests:
          storage: 5Gi       # ← ajustar según volumen de datos esperado

  - metadata:
      name: nifi-conf        # directorio conf con keystore y nifi.properties
    spec:
      accessModes: ["ReadWriteOnce"]
      storageClassName: ""   # ← igual que el anterior
      resources:
        requests:
          storage: 512Mi     # fijo, no necesita ajuste
```

Para ver las StorageClasses disponibles en el clúster:
```bash
kubectl get storageclass
```

Si no se especifica `storageClassName`, Kubernetes usa la StorageClass marcada como `default`.

---

### Paso 5 — Configurar la exposición de la UI (`05-nifi-services.yaml`)

Elegir una de estas opciones según la infraestructura disponible.

#### Opción A — LoadBalancer (recomendada si el clúster tiene un controlador externo)

El servicio `nifi-ui` ya está configurado como `LoadBalancer`. Funciona directamente con cloud providers (AWS EKS, GKE, AKS) o con MetalLB en on-premise.

```yaml
spec:
  type: LoadBalancer
```

Acceso: `https://<EXTERNAL-IP>:8443/nifi`

Para obtener la IP asignada:
```bash
kubectl get svc nifi-ui -n nifi
# La columna EXTERNAL-IP muestra la IP asignada
```

#### Opción B — NodePort (sin LoadBalancer externo)

Descomentar en [05-nifi-services.yaml](05-nifi-services.yaml) la sección `nifi-ui-nodeport` y eliminar o comentar el servicio `nifi-ui` tipo `LoadBalancer`:

```yaml
spec:
  type: NodePort
  ports:
    - port: 8443
      targetPort: 8443
      nodePort: 30443   # ← puerto accesible en cualquier nodo (rango 30000-32767)
```

Acceso: `https://<IP-de-cualquier-nodo>:30443/nifi`

#### Opción C — Ingress (avanzado)

Requiere un Ingress Controller instalado (nginx, traefik, etc.) y configuración adicional no incluida en este repositorio. El Ingress debe configurarse con TLS passthrough para respetar el certificado de NiFi, o con terminación TLS en el Ingress y tráfico HTTP interno (requiere ajustes adicionales en NiFi).

---

### Paso 6 — (Opcional) Ajustar ZooKeeper para producción (`01-zookeeper.yaml`)

El manifiesto incluye ZooKeeper con **1 réplica** (suficiente para desarrollo y pruebas). Para entornos de producción con alta disponibilidad se recomienda un ensemble de **3 nodos**, lo que permite tolerar el fallo de 1 nodo sin perder el quórum.

Para escalar a 3 réplicas, modificar en [01-zookeeper.yaml](01-zookeeper.yaml):
- `spec.replicas: 3`
- La variable `ZOO_SERVERS` debe listar los 3 servidores.

> Para entornos de producción críticos, se recomienda usar un operador de ZooKeeper (p.ej. Strimzi) que gestione el cluster de forma más robusta.

---

### Paso 7 — Desplegar

Una vez configurados todos los ficheros:

```bash
kubectl apply -k .
```

Verificar el arranque:
```bash
# Monitorizar en tiempo real (Ctrl+C para salir)
kubectl get pods -n nifi -w

# Estado esperado tras 3-8 minutos:
# NAME          READY   STATUS    RESTARTS
# zookeeper-0   1/1     Running   0
# nifi-0        1/1     Running   0
# nifi-1        1/1     Running   0
```

> NiFi tarda entre **3 y 8 minutos** en el primer arranque (inicialización de repositorios y TLS). Es normal ver los pods en `0/1 Running` durante ese tiempo.

Si algún pod no arranca, revisar los logs:
```bash
kubectl logs -n nifi nifi-0
kubectl describe pod -n nifi nifi-0   # muestra eventos y errores de scheduling
```

---

## Verificación del despliegue

### Verificar que el clúster se ha formado correctamente

```bash
# Obtener token de autenticación
TOKEN=$(kubectl exec -n nifi nifi-0 -- bash -c '
  curl -k -s -X POST \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -d "username=<USUARIO>&password=<PASSWORD>" \
    https://nifi-0.nifi-headless.nifi.svc.cluster.local:8443/nifi-api/access/token
')

# Consultar nodos del clúster
kubectl exec -n nifi nifi-0 -- bash -c "
  curl -k -s \
    -H 'Authorization: Bearer $TOKEN' \
    https://nifi-0.nifi-headless.nifi.svc.cluster.local:8443/nifi-api/controller/cluster
"
```

La respuesta debe mostrar ambos nodos con `"status":"CONNECTED"`.

### Verificar desde la UI

1. Abrir `https://<ip-o-hostname>:8443/nifi` en el navegador.
2. Aceptar el aviso de certificado autofirmado (es el certificado generado en el Paso 1).
3. Iniciar sesión con las credenciales configuradas en `03-nifi-secret.yaml`.
4. Ir a **menú ≡ → Cluster** y comprobar que aparecen todos los nodos con estado `Connected`.

---

## Comandos de operación

```bash
# Ver logs de NiFi
kubectl logs -n nifi nifi-0 -f
kubectl logs -n nifi nifi-1 -f

# Describir un pod (eventos, errores de arranque)
kubectl describe pod -n nifi nifi-0

# Abrir shell dentro de un pod
kubectl exec -it -n nifi nifi-0 -- bash

# Aplicar cambios de configuración y reiniciar
kubectl apply -k .
kubectl rollout restart statefulset/nifi -n nifi

# Escalar el clúster (actualizar también NIFI_CLUSTER_NODES en el StatefulSet)
kubectl scale statefulset/nifi -n nifi --replicas=3

# Eliminar todo el despliegue (namespace + recursos)
kubectl delete namespace nifi
# Los PVCs requieren eliminación explícita (contienen datos persistentes):
kubectl delete pvc --all -n nifi
```

---

## Tabla resumen de variables a configurar

Todos los valores que deben revisarse antes del despliegue:

| Fichero | Campo | Descripción | ¿Cambiar? |
|---|---|---|---|
| `setup-tls.ps1` | `-StorePassword` | Contraseña del keystore y truststore | **Obligatorio** |
| `setup-tls.ps1` | `-Namespace` | Namespace Kubernetes | Si no se usa `nifi` |
| `setup-tls.ps1` | `-ClusterDomain` | Dominio DNS interno del clúster | Si no es `cluster.local` |
| `setup-tls.ps1` | `-AdditionalDnsNames` | SANs adicionales (nombre DNS externo, Ingress) | Si se accede con FQDN externo |
| `03-nifi-secret.yaml` | `NIFI_USERNAME` | Usuario administrador NiFi | **Obligatorio** |
| `03-nifi-secret.yaml` | `NIFI_PASSWORD` | Contraseña del usuario (≥ 12 caracteres) | **Obligatorio** |
| `03-nifi-secret.yaml` | `NIFI_SENSITIVE_PROPS_KEY` | Clave de cifrado del flujo (≥ 12 caracteres, igual en todos los nodos) | **Obligatorio** |
| `04-nifi-statefulset.yaml` | `spec.replicas` | Número de nodos NiFi | Según necesidad (mínimo 1) |
| `04-nifi-statefulset.yaml` | `env.NIFI_CLUSTER_NODES` | Debe coincidir con `replicas` | Siempre que se cambie `replicas` |
| `04-nifi-statefulset.yaml` | `resources.requests/limits` | CPU y RAM por pod | Según capacidad del clúster |
| `04-nifi-statefulset.yaml` | `volumeClaimTemplates[*].storageClassName` | StorageClass para los PVCs | Si no hay StorageClass por defecto |
| `04-nifi-statefulset.yaml` | `volumeClaimTemplates[nifi-data].storage` | Tamaño del volumen de datos por pod | Según volumen de datos esperado |
| `05-nifi-services.yaml` | `spec.type` del servicio `nifi-ui` | `LoadBalancer`, `NodePort` | Según infraestructura de red |
| `01-zookeeper.yaml` | `spec.replicas` | Réplicas de ZooKeeper (1 = dev, 3 = producción) | Recomendado 3 en producción |

---

## Comparativa desarrollo vs. producción

| Aspecto | Desarrollo (Docker Desktop) | Producción (on-premise) |
|---|---|---|
| NiFi réplicas | 2 | 3+ |
| ZooKeeper réplicas | 1 | 3 |
| StorageClass | `hostpath` (default) | Ceph, NFS, Longhorn, etc. |
| Exposición UI | LoadBalancer → `localhost:8443` | LoadBalancer con IP fija / NodePort / Ingress |
| TLS | Autofirmado (setup-tls.ps1) | Cert-manager + CA corporativa |
| Autenticación | Single User | LDAP / OIDC |
| RAM por pod | 2–4 GB | 4–16 GB según carga |

---

## Consideraciones de seguridad para producción

- **Certificados**: los generados por `setup-tls.ps1` son autofirmados. Para producción usar cert-manager con una CA corporativa o pública.
- **Secretos**: los valores en `03-nifi-secret.yaml` son de ejemplo. En producción gestionarlos con Vault, Sealed Secrets o External Secrets Operator para no almacenar credenciales en el repositorio.
- **Autenticación**: Single User está pensado para entornos simples o de prueba. Para producción con múltiples usuarios o integración corporativa, configurar LDAP u OIDC (requiere modificar `02-nifi-configmap.yaml`).
- **Red**: verificar que las NetworkPolicies del clúster permiten comunicación entre pods NiFi en los puertos `8443` (HTTPS/API), `11443` (protocolo de clúster) y `10443` (Site-to-Site).
- **`NIFI_SENSITIVE_PROPS_KEY`**: esta clave protege las credenciales almacenadas dentro de los diseños de flujo. Guardarla en un lugar seguro; si se pierde o cambia, los flujos existentes con credenciales cifradas dejarán de funcionar.
