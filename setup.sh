#!/usr/bin/env bash
# setup.sh
# Run once when setting up a new project on Linux/macOS
# Requirement:
#   - Push v0.0 to GitHub first
#   - Ensure GitHub Actions runner is running
#
# Usage:
#   chmod +x setup.sh && ./setup.sh

set -euo pipefail

echo ""
echo "========================================"
echo "   MLOps Stack Setup"
echo "========================================"
echo ""

# =========================================================
# Step 1: Check required tools
# =========================================================

echo "[1/9] Checking tools..."

tools=(minikube helm kubectl docker git python)

for tool in "${tools[@]}"; do
    if ! command -v "$tool" &>/dev/null; then
        echo "ERROR: $tool is not installed. Please install it first."
        exit 1
    fi
done

echo "OK: All required tools are ready"

# =========================================================
# Step 2: Ensure Minikube is running
# =========================================================

echo ""
echo "[2/9] Checking Minikube..."

status=$(minikube status --format="{{.Host}}" 2>/dev/null || true)

if [ "$status" != "Running" ]; then
    echo "Minikube is not running. Starting..."
    minikube start --memory=4096 --cpus=2
fi

echo "OK: Minikube is running"

# =========================================================
# Step 3: Build Docker images
# =========================================================
#
# Reason:
# Docker images do not depend on dataset,
# so they can be built before DVC/data exists.
#
# =========================================================

echo ""
echo "[3/9] Building Docker images..."

# -----------------------------------------------------
# Build shared base image
# -----------------------------------------------------

echo "Building base image..."
docker build \
    -f docker/Dockerfile.base \
    -t image-classifier-base:latest \
    .

# -----------------------------------------------------
# Build trainer image
# -----------------------------------------------------

echo "Building trainer image..."
docker build \
    -f docker/Dockerfile.trainer \
    -t image-classifier-trainer:latest \
    .

# -----------------------------------------------------
# Build API image
# -----------------------------------------------------

echo "Building API image..."
docker build \
    -f docker/Dockerfile.api \
    -t image-classifier-api:latest \
    .

# -----------------------------------------------------
# Load images into Minikube
# -----------------------------------------------------

echo "Loading images into Minikube..."
minikube image load image-classifier-base:latest
minikube image load image-classifier-trainer:latest
minikube image load image-classifier-api:latest

echo "OK: Images loaded into Minikube"

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

echo ""
echo "[4/9] Deploying stack via Helm..."

if helm list -n mlops --short 2>/dev/null | grep -q "^mlops$"; then
    echo "Stack already exists, skipping."
else
    helm install \
        mlops \
        mlops_chart/ \
        --namespace mlops \
        --create-namespace

    echo "OK: Helm install completed"
fi

# =========================================================
# Step 5: Wait for MinIO
# =========================================================

echo ""
echo "[5/9] Waiting for MinIO..."

# Wait StatefulSet rollout first
kubectl rollout status \
    statefulset/minio \
    -n mlops \
    --timeout=120s

# Wait Pod Ready condition
echo "  Waiting for MinIO pod to be ready..."

kubectl wait pod \
    -n mlops \
    -l app=minio \
    --for=condition=Ready \
    --timeout=120s

echo "OK: MinIO is ready"

# =========================================================
# Step 6: Initialize DVC
# =========================================================
#
# Reason:
# Read credentials from Helm values.yaml
# instead of hardcoding them.
#
# =========================================================

echo ""
echo "[6/9] Initializing DVC..."

if [ ! -d ".dvc" ]; then

    values_content=$(cat mlops_chart/values.yaml)

    minio_user=$(echo "$values_content" | grep 'minioRootUser:' | sed 's/.*minioRootUser:\s*"\?\([^"]*\)"\?.*/\1/' | tr -d '[:space:]')
    minio_pass=$(echo "$values_content" | grep 'minioRootPassword:' | sed 's/.*minioRootPassword:\s*"\?\([^"]*\)"\?.*/\1/' | tr -d '[:space:]')

    if [ -z "$minio_user" ] || [ -z "$minio_pass" ]; then
        echo "ERROR: Cannot read MinIO credentials from values.yaml"
        exit 1
    fi

    # -----------------------------------------------------
    # DVC init
    # -----------------------------------------------------

    python -m dvc init

    # -----------------------------------------------------
    # Create remote cleanly
    # -----------------------------------------------------

    echo "Creating DVC remote..."

    if python -m dvc remote list | grep -q "^minio"; then
        echo "Removing existing remote..."
        python -m dvc remote remove minio
    else
        echo "Remote minio does not exist"
    fi

    # Create remote
    python -m dvc remote add \
        -d \
        minio \
        s3://dvc

    # Configure remote
    # localhost is used because this script
    # accesses MinIO through kubectl port-forward

    python -m dvc remote modify \
        minio \
        endpointurl \
        http://localhost:9000

    python -m dvc remote modify \
        minio \
        use_ssl \
        false

    python -m dvc remote modify \
        --local \
        minio \
        access_key_id \
        "$minio_user"

    python -m dvc remote modify \
        --local \
        minio \
        secret_access_key \
        "$minio_pass"

    echo "OK: DVC remote configured"

    # -----------------------------------------------------
    # Git commit
    # -----------------------------------------------------

    git add .dvc .dvcignore

    if ! git diff --cached --quiet; then
        git commit -m "initialize DVC"
    fi

    echo "OK: DVC initialized"

else
    echo "DVC already initialized, skipping."
fi

# =========================================================
# Step 7: Wait for dataset
# =========================================================

echo ""
echo "[7/9] Waiting for data/..."

echo "  Copy dataset into data/ using format:"
echo "     data/train/<class>/"
echo "     data/val/<class>/"
echo ""

spinner='|/-\'
i=0

while [ ! -d "data" ] || [ -z "$(find data -type f 2>/dev/null)" ]; do
    char="${spinner:$((i % 4)):1}"
    printf "\r  Waiting for dataset files in data/ %s (Ctrl+C to cancel)" "$char"
    sleep 0.2
    i=$((i + 1))
done

printf "\r  OK: data/ detected                     \n"

# =========================================================
# Step 8: DVC add + push
# =========================================================
#
# Reason:
# First dataset push must be done manually
# because CI/CD does not yet have data.dvc.
#
# =========================================================

echo ""
echo "[8/9] Tracking data and pushing to MinIO..."

# -----------------------------------------------------
# Start MinIO port-forward (background)
# -----------------------------------------------------

kubectl port-forward \
    -n mlops \
    svc/minio-service \
    9000:9000 &

PF_PID=$!

# Cleanup port-forward on script exit
cleanup() {
    kill "$PF_PID" 2>/dev/null || true
}
trap cleanup EXIT

# -----------------------------------------------------
# Wait for port-forward ready
# -----------------------------------------------------

max=15
i=0
connected=false

while [ "$i" -lt "$max" ]; do
    sleep 2
    i=$((i + 1))

    if curl -sf --max-time 3 "http://127.0.0.1:9000/minio/health/live" &>/dev/null; then
        connected=true
        break
    fi

    echo "  Waiting for MinIO port-forward... ($i/$max)"
done

if [ "$connected" != "true" ]; then
    echo ""
    echo "ERROR: MinIO port-forward failed!"
    exit 1
fi

echo "OK: MinIO port-forward established"

# -----------------------------------------------------
# Verify DVC remote exists
# -----------------------------------------------------

if ! python -m dvc remote list | grep -q "^minio[[:space:]]"; then
    echo ""
    echo "ERROR: DVC remote 'minio' does not exist!"
    echo ""
    echo "Current remotes:"
    python -m dvc remote list
    exit 1
fi

# -----------------------------------------------------
# DVC add
# -----------------------------------------------------

echo "Adding dataset to DVC..."
python -m dvc add data/
echo "OK: Dataset tracked by DVC"

# -----------------------------------------------------
# DVC push
# -----------------------------------------------------

echo "Pushing dataset to MinIO..."
python -m dvc push -r minio
echo "OK: Data pushed to MinIO"

# Cleanup port-forward
kill "$PF_PID" 2>/dev/null || true

# =========================================================
# Step 9: Create dvc-pointer ConfigMap + push GitHub
# =========================================================
#
# Reason:
# Kubernetes trainer Job needs data.dvc
# to know which dataset version should be pulled.
#
# =========================================================

echo ""
echo "[9/9] Creating dvc-pointer ConfigMap and pushing to GitHub..."

kubectl create configmap dvc-pointer \
    --from-file=data.dvc=data.dvc \
    -n mlops \
    --dry-run=client \
    -o yaml \
    | kubectl apply -f -

echo "OK: dvc-pointer ConfigMap created"

git add data.dvc .gitignore

if ! git diff --cached --quiet; then
    git commit -m "dataset v1"
fi

git tag v1.0 2>/dev/null || true

branch=$(git rev-parse --abbrev-ref HEAD)
git push origin "$branch" --tags

echo "OK: Pushed to GitHub, CI/CD is running"

echo ""
echo "========================================"
echo "   Setup completed!"
echo "========================================"
echo ""
echo "CI/CD is running on GitHub Actions."
echo "Monitor at: GitHub repo -> Actions"
echo ""
echo "After CI/CD completes, run:"
echo "  kubectl port-forward -n mlops svc/mlflow-service 5000:5000"
echo "  kubectl port-forward -n mlops svc/api-service 8000:8000"
echo "  kubectl port-forward -n mlops svc/grafana-service 3000:3000"
echo "  kubectl port-forward -n mlops svc/minio-service 9001:9001"