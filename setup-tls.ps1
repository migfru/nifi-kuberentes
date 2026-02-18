param(
    [string]$Namespace = "nifi",
    [string]$SecretName = "nifi-tls",
    [string]$OutputDir = "tls",
    [string]$StorePassword = "nifi1234",
    [string]$KeyAlias = "nifi",
    [string]$ClusterDomain = "cluster.local",
    [string[]]$AdditionalDnsNames = @(),
    [switch]$SkipSecret
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Assert-Command {
    param([string]$Name)
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "No se encontro el comando requerido: $Name"
    }
}

Assert-Command -Name "docker"
if (-not $SkipSecret) {
    Assert-Command -Name "kubectl"
}

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$outputPath = Join-Path $scriptRoot $OutputDir
New-Item -Path $outputPath -ItemType Directory -Force | Out-Null

$keystorePath = Join-Path $outputPath "keystore.p12"
$truststorePath = Join-Path $outputPath "truststore.p12"
$certPath = Join-Path $outputPath "nifi.crt"

Remove-Item -Path $keystorePath, $truststorePath, $certPath -ErrorAction SilentlyContinue

$sanList = @(
    "*.nifi-headless.$Namespace.svc.$ClusterDomain",
    "nifi-headless.$Namespace.svc.$ClusterDomain",
    "nifi.$Namespace.svc.$ClusterDomain",
    "localhost"
)

$sanList = @($sanList + $AdditionalDnsNames) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique

$san = ($sanList | ForEach-Object { "DNS:$_" }) -join ","
$san = "$san,IP:127.0.0.1"

$dname = "CN=*.nifi-headless.$Namespace.svc.$ClusterDomain,OU=NiFi,O=NiFi,L=NA,ST=NA,C=US"

Write-Host "Generando keystore/truststore compartidos en: $outputPath"

$containerCommand = 'keytool -genkeypair -alias "$KEY_ALIAS" -keyalg RSA -keysize 4096 -validity 3650 -dname "$DNAME" -ext SAN="$SAN" -keystore /work/keystore.p12 -storetype PKCS12 -storepass "$STORE_PASSWORD" -keypass "$STORE_PASSWORD" && keytool -exportcert -alias "$KEY_ALIAS" -keystore /work/keystore.p12 -storetype PKCS12 -storepass "$STORE_PASSWORD" -rfc -file /work/nifi.crt && keytool -importcert -alias "$KEY_ALIAS" -file /work/nifi.crt -keystore /work/truststore.p12 -storetype PKCS12 -storepass "$STORE_PASSWORD" -noprompt'

docker run --rm `
    -v "${outputPath}:/work" `
    -e "STORE_PASSWORD=$StorePassword" `
    -e "KEY_ALIAS=$KeyAlias" `
    -e "DNAME=$dname" `
    -e "SAN=$san" `
    eclipse-temurin:21-jdk `
    sh -lc $containerCommand

if (-not (Test-Path $keystorePath) -or -not (Test-Path $truststorePath)) {
    throw "No se generaron los archivos keystore/truststore."
}

Write-Host "Archivos generados:"
Write-Host " - $keystorePath"
Write-Host " - $truststorePath"
Write-Host " - $certPath"

if ($SkipSecret) {
    Write-Host "SkipSecret activo: no se actualizo el Secret en Kubernetes."
    exit 0
}

Write-Host "Actualizando Secret '$SecretName' en namespace '$Namespace'..."

kubectl create secret generic $SecretName `
    -n $Namespace `
    --from-file="keystore.p12=$keystorePath" `
    --from-file="truststore.p12=$truststorePath" `
    --from-literal="keystorePassword=$StorePassword" `
    --from-literal="keyPassword=$StorePassword" `
    --from-literal="truststorePassword=$StorePassword" `
    --dry-run=client -o yaml | kubectl apply -f -

Write-Host "Secret actualizado correctamente."
