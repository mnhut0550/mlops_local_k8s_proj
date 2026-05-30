# setup.ps1
# Run once when setting up a new project on Windows
# Requirement:
#   - Push v0.0 to GitHub first
#   - Ensure GitHub Actions runner is running
#
# Usage:
#   .\setup.ps1

$ErrorActionPreference = "Stop"

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "   MLOps Stack Setup" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

# =========================================================
# Step 1: Check required tools
# =========================================================

Write-Host "[1/9] Checking tools..." -ForegroundColor Yellow

$tools = @(
    "minikube",
    "helm",
    "kubectl",
    "docker",
    "git",
    "python"
)

foreach ($tool in $tools) {

    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {

        Write-Host `
            "ERROR: $tool is not installed. Please install it first." `
            -ForegroundColor Red

        exit 1
    }
}

Write-Host "OK: All required tools are ready" -ForegroundColor Green

# =========================================================
# Step 2: Ensure Minikube is running
# =========================================================

Write-Host ""
Write-Host "[2/9] Checking Minikube..." -ForegroundColor Yellow

$status = minikube status --format="{{.Host}}" 2>$null

if ($status -ne "Running") {

    Write-Host `
        "Minikube is not running. Starting..." `
        -ForegroundColor Yellow

    minikube start --memory=4096 --cpus=2

    if ($LASTEXITCODE -ne 0) {
        Write-Host "ERROR: Failed to start Minikube!" -ForegroundColor Red
        exit 1
    }
}

Write-Host "OK: Minikube is running" -ForegroundColor Green

# =========================================================
# Step 3: Build Docker images
# =========================================================
#
# Reason:
# Docker images do not depend on dataset,
# so they can be built before DVC/data exists.
#
# =========================================================
# =========================================================
# Step 3: Build Docker images
# =========================================================

Write-Host ""
Write-Host "[3/9] Building Docker images..." -ForegroundColor Yellow

# -----------------------------------------------------
# Build shared base image
# -----------------------------------------------------

Write-Host `
    "Building base image..." `
    -ForegroundColor Cyan

docker build `
    -f docker/Dockerfile.base `
    -t image-classifier-base:latest `
    .

if ($LASTEXITCODE -ne 0) {

    Write-Host `
        "ERROR: Failed to build base image!" `
        -ForegroundColor Red

    exit 1
}

# -----------------------------------------------------
# Build trainer image
# -----------------------------------------------------

Write-Host `
    "Building trainer image..." `
    -ForegroundColor Cyan

docker build `
    -f docker/Dockerfile.trainer `
    -t image-classifier-trainer:latest `
    .

if ($LASTEXITCODE -ne 0) {

    Write-Host `
        "ERROR: Failed to build trainer image!" `
        -ForegroundColor Red

    exit 1
}

# -----------------------------------------------------
# Build API image
# -----------------------------------------------------

Write-Host `
    "Building API image..." `
    -ForegroundColor Cyan

docker build `
    -f docker/Dockerfile.api `
    -t image-classifier-api:latest `
    .

if ($LASTEXITCODE -ne 0) {

    Write-Host `
        "ERROR: Failed to build API image!" `
        -ForegroundColor Red

    exit 1
}

# -----------------------------------------------------
# Load images into Minikube
# -----------------------------------------------------

Write-Host `
    "Loading images into Minikube..." `
    -ForegroundColor Cyan

minikube image load image-classifier-base:latest
minikube image load image-classifier-trainer:latest
minikube image load image-classifier-api:latest

if ($LASTEXITCODE -ne 0) {

    Write-Host `
        "ERROR: Failed to load images into Minikube!" `
        -ForegroundColor Red

    exit 1
}

Write-Host `
    "OK: Images loaded into Minikube" `
    -ForegroundColor Green

# =========================================================
# Step 4: Deploy stack via Helm
# =========================================================
#
# Reason:
# Deploy infrastructure first:
#   - MinIO
#   - MLflow
#   - Prometheus
#   - Grafana
#
# Trainer/API are not active yet because
# dataset has not been added.
#
# =========================================================

Write-Host ""
Write-Host "[4/9] Deploying stack via Helm..." -ForegroundColor Yellow

$release = helm list -n mlops --short 2>$null

if ($release -contains "mlops") {

    Write-Host `
        "Stack already exists, skipping." `
        -ForegroundColor Gray
}
else {

    helm install `
        mlops `
        mlops_chart/ `
        --namespace mlops `
        --create-namespace

    if ($LASTEXITCODE -ne 0) {

        Write-Host `
            "ERROR: Helm install failed!" `
            -ForegroundColor Red

        exit 1
    }

    Write-Host `
        "OK: Helm install completed" `
        -ForegroundColor Green
}

# =========================================================
# Step 5: Wait for MinIO
# =========================================================

Write-Host ""
Write-Host "[5/9] Waiting for MinIO..." -ForegroundColor Yellow

# Wait StatefulSet rollout first
kubectl rollout status `
    statefulset/minio `
    -n mlops `
    --timeout=120s

if ($LASTEXITCODE -ne 0) {

    Write-Host `
        "ERROR: MinIO rollout failed!" `
        -ForegroundColor Red

    exit 1
}

# Wait Pod Ready condition
Write-Host "  Waiting for MinIO pod to be ready..."

kubectl wait pod `
    -n mlops `
    -l app=minio `
    --for=condition=Ready `
    --timeout=120s

if ($LASTEXITCODE -ne 0) {

    Write-Host `
        "ERROR: MinIO timeout!" `
        -ForegroundColor Red

    exit 1
}

Write-Host "OK: MinIO is ready" -ForegroundColor Green

# =========================================================
# Step 6: Initialize DVC
# =========================================================
#
# Reason:
# Read credentials from Helm values.yaml
# instead of hardcoding them.
# =========================================================

Write-Host ""
Write-Host "[6/9] Initializing DVC..." -ForegroundColor Yellow

if (-not (Test-Path ".dvc")) {

    $valuesContent = Get-Content `
        "mlops_chart/values.yaml" `
        -Raw

    $minioUser = (
        $valuesContent |
        Select-String 'minioRootUser:\s+"?([^"\n]+)"?'
    ).Matches.Groups[1].Value.Trim()

    $minioPass = (
        $valuesContent |
        Select-String 'minioRootPassword:\s+"?([^"\n]+)"?'
    ).Matches.Groups[1].Value.Trim()

    if (
        [string]::IsNullOrEmpty($minioUser) -or
        [string]::IsNullOrEmpty($minioPass)
    ) {

        Write-Host `
            "ERROR: Cannot read MinIO credentials from values.yaml" `
            -ForegroundColor Red

        exit 1
    }

    # -----------------------------------------------------
    # DVC init
    # -----------------------------------------------------

    python -m dvc init

    if ($LASTEXITCODE -ne 0) {

        Write-Host `
            "ERROR: DVC init failed!" `
            -ForegroundColor Red

        exit 1
    }

    # -----------------------------------------------------
    # Create remote cleanly
    # -----------------------------------------------------

    Write-Host `
        "Creating DVC remote..." `
        -ForegroundColor Cyan

    $remoteExists = python -m dvc remote list | Select-String "^minio"

    Write-Host "remoteExists = $remoteExists"

    if ($remoteExists) {
        Write-Host "Removing existing remote..."
        python -m dvc remote remove minio
    }
    else {
        Write-Host "Remote minio does not exist"
    }

    # Create remote
    python -m dvc remote add `
        -d `
        minio `
        s3://dvc

    if ($LASTEXITCODE -ne 0) {

        Write-Host ""
        Write-Host `
            "ERROR: Failed to create DVC remote!" `
            -ForegroundColor Red

        Write-Host `
            "Current remotes:" `
            -ForegroundColor Yellow

        python -m dvc remote list

        exit 1
    }

    Write-Host `
        "OK: DVC remote created" `
        -ForegroundColor Green

    # -----------------------------------------------------
    # Configure remote
    # -----------------------------------------------------

    # localhost is used because this script
    # accesses MinIO through kubectl port-forward

    python -m dvc remote modify `
        minio `
        endpointurl `
        http://localhost:9000

    if ($LASTEXITCODE -ne 0) {

        Write-Host `
            "ERROR: Failed to configure endpointurl!" `
            -ForegroundColor Red

        exit 1
    }

    python -m dvc remote modify `
        minio `
        use_ssl `
        false

    if ($LASTEXITCODE -ne 0) {

        Write-Host `
            "ERROR: Failed to configure use_ssl!" `
            -ForegroundColor Red

        exit 1
    }

    python -m dvc remote modify `
        --local `
        minio `
        access_key_id `
        $minioUser

    if ($LASTEXITCODE -ne 0) {

        Write-Host `
            "ERROR: Failed to configure access_key_id!" `
            -ForegroundColor Red

        exit 1
    }

    python -m dvc remote modify `
        --local `
        minio `
        secret_access_key `
        $minioPass

    if ($LASTEXITCODE -ne 0) {

        Write-Host `
            "ERROR: Failed to configure secret_access_key!" `
            -ForegroundColor Red

        exit 1
    }

    Write-Host `
        "OK: DVC remote configured" `
        -ForegroundColor Green

    # -----------------------------------------------------
    # Git commit
    # -----------------------------------------------------

    git add .dvc .dvcignore

    # git diff --cached --quiet returns:
    #   0 = no staged changes
    #   1 = staged changes exist
    cmd /c "git diff --cached --quiet"

    if ($LASTEXITCODE -ne 0) {

        git commit -m "initialize DVC"

        if ($LASTEXITCODE -ne 0) {

            Write-Host `
                "ERROR: Failed to commit DVC files!" `
                -ForegroundColor Red

            exit 1
        }
    }

    Write-Host `
        "OK: DVC initialized" `
        -ForegroundColor Green
}
else {

    Write-Host `
        "DVC already initialized, skipping." `
        -ForegroundColor Gray
}

# =========================================================
# Step 7: Wait for dataset
# =========================================================

Write-Host ""
Write-Host "[7/9] Waiting for data/..." -ForegroundColor Yellow

Write-Host `
    "  Copy dataset into data/ using format:" `
    -ForegroundColor White

Write-Host `
    "     data/train/<class>/" `
    -ForegroundColor Gray

Write-Host `
    "     data/val/<class>/" `
    -ForegroundColor Gray

Write-Host ""

$spinner = @('|', '/', '-', '\')
$i = 0

while (
    -not (Test-Path "data") -or
    (Get-ChildItem "data" -Recurse -File).Count -eq 0
) {

    $char = $spinner[$i % $spinner.Length]

    Write-Host -NoNewline `
        "`r  Waiting for dataset files in data/ $char (Ctrl+C to cancel)"

    Start-Sleep -Milliseconds 200

    $i++
}

Write-Host `
    "`r  OK: data/ detected                     " `
    -ForegroundColor Green

# =========================================================
# Step 8: DVC add + push
# =========================================================
#
# Reason:
# First dataset push must be done manually
# because CI/CD does not yet have data.dvc.
#
# =========================================================

Write-Host ""
Write-Host "[8/9] Tracking data and pushing to MinIO..." -ForegroundColor Yellow

# -----------------------------------------------------
# Start MinIO port-forward
# -----------------------------------------------------

$kubectl = (Get-Command kubectl).Source

$pfJob = Start-Job -ScriptBlock {
    param($kubectlPath)

    & $kubectlPath port-forward `
        -n mlops `
        svc/minio-service `
        9000:9000

} -ArgumentList $kubectl

# Cleanup automatically on PowerShell exit
$jobId = $pfJob.Id

Register-EngineEvent `
    -SourceIdentifier PowerShell.Exiting `
    -Action {

        Stop-Job `
            -Id $jobId `
            -ErrorAction SilentlyContinue

        Remove-Job `
            -Id $jobId `
            -ErrorAction SilentlyContinue

    } | Out-Null

# -----------------------------------------------------
# Wait for port-forward ready
# -----------------------------------------------------

$max = 15
$i = 0
$connected = $false

do {

    Start-Sleep -Seconds 2
    $i++

    try {

        $response = Invoke-WebRequest `
            -Uri "http://127.0.0.1:9000/minio/health/live" `
            -UseBasicParsing `
            -TimeoutSec 3

        if ($response.StatusCode -eq 200) {

            $connected = $true
            break
        }
    }
    catch {
    }

    Write-Host `
        "  Waiting for MinIO port-forward... ($i/$max)" `
        -ForegroundColor Gray

} while ($i -lt $max)

if (-not $connected) {

    Write-Host ""
    Write-Host `
        "ERROR: MinIO port-forward failed!" `
        -ForegroundColor Red

    Write-Host ""
    Write-Host `
        "Port-forward logs:" `
        -ForegroundColor Yellow

    Receive-Job `
        -Id $pfJob.Id `
        -Keep

    exit 1
}

Write-Host `
    "OK: MinIO port-forward established" `
    -ForegroundColor Green

# -----------------------------------------------------
# Verify DVC remote exists
# -----------------------------------------------------

$dvcRemote = python -m dvc remote list

if ($dvcRemote -notmatch "^minio\s") {

    Write-Host ""
    Write-Host `
        "ERROR: DVC remote 'minio' does not exist!" `
        -ForegroundColor Red

    Write-Host ""
    Write-Host `
        "Current remotes:" `
        -ForegroundColor Yellow

    python -m dvc remote list

    exit 1
}

# -----------------------------------------------------
# DVC add
# -----------------------------------------------------

Write-Host `
    "Adding dataset to DVC..." `
    -ForegroundColor Cyan

python -m dvc add data/

if ($LASTEXITCODE -ne 0) {

    Write-Host ""
    Write-Host `
        "ERROR: DVC add failed!" `
        -ForegroundColor Red

    exit 1
}

Write-Host `
    "OK: Dataset tracked by DVC" `
    -ForegroundColor Green

# -----------------------------------------------------
# DVC push
# -----------------------------------------------------

Write-Host `
    "Pushing dataset to MinIO..." `
    -ForegroundColor Cyan

python -m dvc push -r minio

if ($LASTEXITCODE -ne 0) {

    Write-Host ""
    Write-Host `
        "ERROR: DVC push failed!" `
        -ForegroundColor Red

    Write-Host ""
    Write-Host `
        "Checking MinIO port-forward job..." `
        -ForegroundColor Yellow

    Receive-Job `
        -Id $pfJob.Id `
        -Keep

    exit 1
}

Write-Host `
    "OK: Data pushed to MinIO" `
    -ForegroundColor Green

# -----------------------------------------------------
# Cleanup
# -----------------------------------------------------

Stop-Job `
    $pfJob `
    -ErrorAction SilentlyContinue

Remove-Job `
    $pfJob `
    -ErrorAction SilentlyContinue

# =========================================================
# Step 9: Create dvc-pointer ConfigMap + push GitHub
# =========================================================
#
# Reason:
# Kubernetes trainer Job needs data.dvc
# to know which dataset version should be pulled.
#
# =========================================================

Write-Host ""
Write-Host "[9/9] Creating dvc-pointer ConfigMap and pushing to GitHub..." -ForegroundColor Yellow

$configmapYaml = kubectl create configmap dvc-pointer `
    --from-file=data.dvc=data.dvc `
    -n mlops `
    --dry-run=client `
    -o yaml

if ($LASTEXITCODE -ne 0) {

    Write-Host `
        "ERROR: Failed to generate dvc-pointer ConfigMap!" `
        -ForegroundColor Red

    exit 1
}

$configmapYaml | kubectl apply -f -

if ($LASTEXITCODE -ne 0) {

    Write-Host `
        "ERROR: Failed to apply dvc-pointer ConfigMap!" `
        -ForegroundColor Red

    exit 1
}

Write-Host `
    "OK: dvc-pointer ConfigMap created" `
    -ForegroundColor Green

git add data.dvc .gitignore

# git diff --cached --quiet returns exit code 1 when there ARE staged changes
# (not an error) — isolate it so $ErrorActionPreference = Stop doesn't trigger
cmd /c "git diff --cached --quiet"

if ($LASTEXITCODE -ne 0) {

    git commit -m "dataset v1"
}

git tag v1.0 2>$null

$branch = git rev-parse --abbrev-ref HEAD

git push origin $branch --tags

Write-Host `
    "OK: Pushed to GitHub, CI/CD is running" `
    -ForegroundColor Green

# Cleanup background jobs
Stop-Job $pfJob -ErrorAction SilentlyContinue
Remove-Job $pfJob -ErrorAction SilentlyContinue

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "   Setup completed!" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

Write-Host `
    "CI/CD is running on GitHub Actions." `
    -ForegroundColor White

Write-Host `
    "Monitor at: GitHub repo -> Actions" `
    -ForegroundColor White

Write-Host ""

Write-Host `
    "After CI/CD completes, run:" `
    -ForegroundColor White

Write-Host `
    "  kubectl port-forward -n mlops svc/mlflow-service 5000:5000" `
    -ForegroundColor Gray

Write-Host `
    "  kubectl port-forward -n mlops svc/api-service 8000:8000" `
    -ForegroundColor Gray

Write-Host `
    "  kubectl port-forward -n mlops svc/grafana-service 3000:3000" `
    -ForegroundColor Gray

Write-Host `
    "  kubectl port-forward -n mlops svc/minio-service 9001:9001" `
    -ForegroundColor Gray