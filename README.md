# MLOps Demo — Image Classification (Kubernetes)

Template MLOps đầy đủ cho bài toán phân loại ảnh, chạy trên Kubernetes local với Helm.

---

## Tại sao cần MLOps?

Train model xong là bước khởi đầu, không phải kết thúc. Vấn đề thật sự bắt đầu sau đó:

- Train đi train lại nhiều lần với params khác nhau — không nhớ lần nào cho kết quả tốt nhất
- Data thay đổi — không biết model đang chạy được train trên data phiên bản nào
- Muốn người khác dùng model — không biết deploy thế nào
- Model đang chạy production — không biết có đang hoạt động đúng không

MLOps giải quyết tất cả bằng cách tự động hóa toàn bộ pipeline:

```
Data → Train → Evaluate → Deploy → Monitor → (Retrain khi cần)
```

---

## Các thành phần

### MLflow — Theo dõi quá trình train
Mỗi lần train, MLflow tự động ghi lại params đã dùng, metrics từng epoch và model weights tốt nhất. Sau nhiều lần chạy, vào `http://localhost:5000` để so sánh.

### MinIO — Lưu trữ file
MinIO là S3 chạy local. Dùng để lưu model files sau khi train và dataset (thông qua DVC).

### FastAPI — Serve model
```
POST http://localhost:8000/predict
→ Gửi ảnh lên → Nhận về kết quả phân loại
```

### Prometheus + Grafana — Monitor
Prometheus thu thập metrics từ API mỗi 15 giây. Grafana vẽ thành dashboard trực quan.

### DVC — Version control cho data
Git lưu code, DVC lưu data. Mỗi khi data thay đổi, DVC tạo một version mới và lưu lên MinIO.

### GitHub Actions — CI/CD
Khi push code hoặc data lên GitHub, pipeline tự động chạy: train lại, chọn model tốt nhất, deploy API mới.

---

## Yêu cầu

- **Docker Desktop** — chạy Minikube
- **Minikube** — Kubernetes local
- **Helm** — package manager cho Kubernetes
- **kubectl** — CLI quản lý Kubernetes
- **Python 3.11+** — chạy DVC
- **Git** — version control
- **DVC**: `pip install dvc dvc-s3`

---

## Cấu trúc project

```
mlops_local_k8s/
├── .github/
│   └── workflows/
│       └── mlops_pipeline.yml   # CI/CD pipeline
├── src/
│   ├── train.py                 # Training script (tự dvc pull trước khi train)
│   ├── params.yaml              # Hyperparams và danh sách model
│   └── models.py                # Định nghĩa các model
├── serving/
│   └── app.py                   # FastAPI serving
├── docker/
│   ├── Dockerfile.trainer       # Docker image cho training
│   └── Dockerfile.api           # Docker image cho API
├── mlops_chart/                 # Helm chart
│   ├── Chart.yaml
│   ├── values.yaml              # Tất cả config — chỉnh sửa ở đây
│   ├── dashboards/
│   │   └── mlops.json           # Grafana dashboard
│   └── templates/               # K8s manifests
├── requirements/
│   ├── trainer.txt
│   └── api.txt
├── setup.ps1                    # Script setup lần đầu (Windows)
└── setup.sh                     # Script setup lần đầu (Linux/macOS)
```

---

# Lần Đầu Setup

> Chỉ cần làm một lần. Script `setup.ps1` / `setup.sh` tự động hóa phần lớn quá trình.

## Bước 1 — Clone project

```bash
git clone https://github.com/mnhut0550/mlops_local_k8s_proj.git
cd mlops_local_k8s_proj
```

## Bước 2 — Cài tools

**Docker Desktop:**
- Windows/macOS: https://www.docker.com/products/docker-desktop
- Sau khi cài, vào Settings → Resources → Memory: tối thiểu 4GB

**Minikube:**
```bash
# macOS
brew install minikube

# Windows (PowerShell — chạy với quyền Admin)
curl -LO https://github.com/kubernetes/minikube/releases/latest/download/minikube-windows-amd64.exe
move minikube-windows-amd64.exe C:\Windows\System32\minikube.exe

# Linux
curl -LO https://storage.googleapis.com/minikube/releases/latest/minikube-linux-amd64
sudo install minikube-linux-amd64 /usr/local/bin/minikube
```

**kubectl:**
```bash
# macOS
brew install kubectl

# Windows
winget install kubectl

# Linux
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
sudo install kubectl /usr/local/bin/kubectl
```

**Helm:**
```bash
# macOS
brew install helm

# Windows (PowerShell — chạy với quyền Admin)
curl -LO https://get.helm.sh/helm-v3.17.0-windows-amd64.zip
Expand-Archive helm-v3.17.0-windows-amd64.zip -DestinationPath helm-tmp
move helm-tmp\windows-amd64\helm.exe C:\Windows\System32\helm.exe
Remove-Item -Recurse helm-tmp, helm-v3.17.0-windows-amd64.zip

# Linux
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
```

**DVC:**
```bash
pip install dvc dvc-s3
```

Kiểm tra tất cả đã cài xong:
```bash
docker version
minikube version
kubectl version --client
helm version
```

## Bước 3 — Cấu hình credentials

Mở file `mlops_chart/values.example.yaml` và chỉnh credentials theo ý muốn:

```yaml
secret:
  minioRootUser: "your_user"       # tối thiểu 3 ký tự
  minioRootPassword: "your_pass"   # tối thiểu 8 ký tự
  awsAccessKeyId: "your_user"      # phải trùng minioRootUser
  awsSecretAccessKey: "your_pass"  # phải trùng minioRootPassword
  grafanaPassword: "your_pass"
```

Sau khi chỉnh xong, lưu file với tên `values.yaml`.

> `values.yaml` đã được thêm vào `.gitignore` để tránh commit credentials thật vào repository.

## Bước 4 — Tạo GitHub repo

1. Vào github.com → **New repository**
2. Đặt tên repo
3. Chọn **Private**
4. **Không check** "Add README"
5. Bấm **Create repository**

Kết nối repo:
```bash
git remote set-url origin https://github.com/<you>/my_project.git
```

## Bước 5 — Push v0.0 lên GitHub

Push code skeleton trước khi setup runner. Lý do: nếu runner chưa có mà pipeline đã trigger thì job sẽ treo chờ runner mãi không có.

```bash
git add .
git commit -m "init project"
git tag v0.0
git push origin main --tags
```

## Bước 6 — Setup CI/CD runner

> Mở một terminal riêng cho bước này. Runner phải đang chạy thì CI/CD mới hoạt động.

```
1. Vào GitHub repo → Settings → Actions → Runners → New self-hosted runner
2. Chọn OS của máy bạn
3. Tạo thư mục riêng cho runner (KHÔNG phải trong project):
   mkdir C:\actions-runner  (Windows)
   mkdir ~/actions-runner   (Linux/macOS)
4. Chạy từng lệnh GitHub hướng dẫn
5. Chạy ./run.cmd (Windows) hoặc ./run.sh (Linux/Mac)
6. Thấy "Listening for Jobs" là runner đã sẵn sàng
```

## Bước 7 — Chạy setup script

> Mỗi lần restart máy cần chạy lại runner và `minikube start`.

Script tự động làm tất cả còn lại theo thứ tự:

1. Kiểm tra tools (minikube, helm, kubectl, docker, git)
2. Khởi động Minikube nếu chưa chạy
3. Build Docker images (trainer + api) và load vào Minikube
4. Deploy toàn bộ stack qua Helm (MinIO, MLflow, Prometheus, Grafana)
5. Đợi MinIO ready
6. Khởi tạo DVC + config remote trỏ vào MinIO
7. **Chờ bạn copy data vào thư mục `data/`**
8. DVC add + push data lên MinIO
9. Git push → trigger CI/CD lần đầu

**Windows PowerShell:**
```powershell
.\setup.ps1
```

**Linux / macOS:**
```bash
chmod +x setup.sh
./setup.sh
```

Khi script hiện thông báo chờ data:
```
⏳ Chưa có data/, đang chờ...
```

Copy dataset vào thư mục `data/` theo format ImageFolder rồi script tự tiếp tục.

*Hiện tại setup.sh đang trong quá trình kiểm thử ,có thể sẽ không hoạt động tốt*.

---

# Format Dataset

Dataset phải theo **ImageFolder format** — mỗi class một folder:

```
data/
├── train/          ← ảnh dùng để train (80%)
│   ├── cat/
│   ├── dog/
│   └── bird/
└── val/            ← ảnh dùng để đánh giá (20%)
    ├── cat/
    ├── dog/
    └── bird/
```

> Classes được tự detect từ tên folder — không cần khai báo ở đâu.

---

# Cấu hình `params.yaml`

```yaml
data:
  data_dir: ./data
  batch_size: 64        # giảm nếu hết RAM
  img_size: 32          # tăng nếu cần độ chính xác cao hơn

training:
  num_epochs: 10
  optimizer: Adam

models:
  - name: SimpleCNN
    lr: 0.001
    freeze_backbone: false

  - name: ResNet18
    lr: 0.0005
    freeze_backbone: true   # chỉ train layer cuối — nhanh hơn nhiều

mlflow:
  experiment_name: my-classification
  registered_model_name: my-classifier
```

---

# Khi Có Data Mới

> Setup đã xong, stack đang chạy — không cần chạy lại `setup.ps1` / `setup.sh`.

```bash
# 0. Port-forward MinIO (DVC cần localhost:9000)
kubectl port-forward -n mlops svc/minio-service 9000:9000

# 1. Thêm hoặc sửa ảnh trong data/

# 2. Xem tags hiện có để đặt tag tiếp theo
git tag --sort=-version:refname

# 3. Track data mới bằng DVC
python -m dvc add data/

# 4. Upload data lên MinIO
python -m dvc push -r minio

# 5. Commit + tag + push → CI/CD tự lo phần còn lại
git add data.dvc
git commit -m "dataset v2 - thêm class bird"
git tag v2.0
git push origin main --tags
# → CI/CD detect data.dvc thay đổi → update ConfigMap dvc-pointer → trainer dvc pull data từ MinIO → train lại → deploy API mới
```

---

# Khi Có Code / Config Mới

> Sửa code training, thêm model, đổi hyperparams — không cần DVC, không cần tag.

```bash
# 1. Sửa file bất kỳ trong src/ hoặc params.yaml

# 2. Commit và push bình thường → CI/CD tự lo phần còn lại
git add .
git commit -m "mô tả thay đổi"
git push origin main
# → CI/CD detect src/** hoặc params.yaml thay đổi → train lại → deploy API mới
```

**Ví dụ hay gặp:**

Thêm model mới — sửa `params.yaml`:
```yaml
models:
  - name: EfficientNetB0
    lr: 0.0003
    freeze_backbone: true
```

Đổi số epoch — sửa `params.yaml`:
```yaml
training:
  num_epochs: 20
```

Sửa logic training — sửa `src/train.py` hoặc `src/models.py` rồi commit như trên.

---

# Chạy Thủ Công

Dùng khi muốn test nhanh mà không cần push lên GitHub:

```bash
# Tạo/cập nhật ConfigMap chứa data.dvc hiện tại
kubectl create configmap dvc-pointer \
  --from-file=data.dvc=data.dvc \
  -n mlops --dry-run=client -o yaml | kubectl apply -f -

# Xóa trainer Job cũ rồi deploy lại
kubectl delete job trainer -n mlops --ignore-not-found
helm upgrade mlops mlops_chart/ --namespace mlops \
  --set trainer.enabled=true \
  --set api.enabled=true

# Theo dõi initContainer kéo data
kubectl logs -n mlops -l job-name=trainer -c dvc-pull -f

# Theo dõi trainer
kubectl logs -n mlops -l job-name=trainer -c trainer -f

# Sau khi trainer xong, restart API
kubectl rollout restart deployment/api -n mlops

# Xem log API
kubectl logs -n mlops -l app=api -f
```

---

# Xem Kết Quả

Cần port-forward để truy cập từ browser. Mỗi service một terminal:

```bash
kubectl port-forward -n mlops svc/mlflow-service 5000:5000
kubectl port-forward -n mlops svc/api-service 8000:8000
kubectl port-forward -n mlops svc/grafana-service 3000:3000
kubectl port-forward -n mlops svc/minio-service 9001:9001
```

## MLflow — http://localhost:5000

Vào **Experiments** → chọn experiment → so sánh các runs. Vào **Models** để thấy model với alias `champion`.

## API — http://localhost:8000/docs

Swagger UI để test trực tiếp:
1. Vào `/predict` → bấm **Try it out**
2. Upload ảnh → bấm **Execute**
3. Nhận kết quả phân loại kèm confidence score

## Grafana — http://localhost:3000

Đăng nhập: `admin` / `grafanaPassword` trong `values.yaml`

Dashboard tự load với các biểu đồ: số request/phút, latency, tỉ lệ lỗi, phân phối class.

## MinIO Console — http://localhost:9001

Đăng nhập bằng `minioRootUser` / `minioRootPassword` trong `values.yaml`. Thấy 2 buckets:
- `mlflow` — model files
- `dvc` — data files

---

# Quản Lý Version Data

## Quy ước đặt tag

| Tag    | Ý nghĩa                        |
|--------|--------------------------------|
| `v0.0` | Project skeleton, chưa có data |
| `v1.0` | Dataset đầu tiên               |
| `v2.0` | Dataset cập nhật lần 2         |

## Rollback về dataset cũ

```bash
# Port-forward MinIO trước
kubectl port-forward -n mlops svc/minio-service 9000:9000 &

git checkout v1.0 -- data.dvc
python -m dvc pull -r minio
# data/ giờ là dataset của v1.0
```

---

# Thêm Model Mới

Thêm vào `params.yaml` rồi push — CI/CD tự train và so sánh:

```yaml
models:
  - name: EfficientNetB0
    lr: 0.0003
    freeze_backbone: true
```

| Model          | Đặc điểm                              |
|----------------|---------------------------------------|
| SimpleCNN      | Tự viết, nhẹ, nhanh                   |
| ResNet18       | Phổ biến, cân bằng tốc độ và accuracy |
| ResNet50       | Chính xác hơn ResNet18, nặng hơn      |
| MobileNetV3    | Tối ưu cho mobile/edge                |
| EfficientNetB0 | Hiệu quả cao, accuracy tốt            |

---

# CI/CD Pipeline

```
git push origin main
        ↓
GitHub Actions trigger khi:
  - src/** thay đổi (code mới)
  - params.yaml thay đổi (thêm model, đổi hyperparams)
  - data.dvc thay đổi (data version mới)
  - Bấm tay trên GitHub UI
        ↓
Kiểm tra data.dvc có không?
  ├── Không có → skip toàn bộ (v0.0, chưa có data)
  └── Có → chạy full pipeline:
        1. Port-forward MinIO
        2. DVC push data mới lên MinIO
        3. Build Docker images nếu code thay đổi
        4. Load images vào Minikube nếu có build mới
        5. Tạo/cập nhật ConfigMap dvc-pointer từ data.dvc
        6. Xóa trainer Job cũ
        7. helm upgrade (bật trainer + api)
           → initContainer mount ConfigMap → dvc pull data về
           → trainer container chạy train.py
        8. Đợi trainer Job complete
        9. Restart API với model champion mới
       10. Health check API
        ↓
✅ Model mới đang serve tự động
```

---

# Luồng MLOps Tổng Thể

```
[Data mới] ──DVC──▶ [MinIO (K8s)]
                        │
                        ▼
[Code/Config] ──Git──▶ [GitHub Actions]
                        │
                        ├─ Tạo ConfigMap dvc-pointer
                        │
                        ▼
                   [Trainer Job (K8s)]
                   initContainer: dvc pull
                   trainer: PyTorch + params.yaml
                        │
                        ▼
                   [MLflow (K8s)]
                   Log metrics, so sánh, chọn champion
                        │
                        ▼
                   [FastAPI Deployment (K8s)]
                   Serve model champion
                        │
                        ▼
                   [Prometheus + Grafana (K8s)]
                   Monitor API health
                        │
                        ▼
               Accuracy giảm? Data drift?
                        │
                        ▼
              Thêm data mới → git push → lặp lại
```

---

# Dùng Template Này Cho Project Mới

```bash
git clone https://github.com/mnhut0550/mlops_local_k8s.git my_project
cd my_project

# Trỏ sang repo mới
git remote remove origin
git remote add origin https://github.com/<you>/my_project.git

# Reset history sạch
git checkout --orphan fresh
git add .
git commit -m "init from mlops template"
git push origin fresh:main

# Đổi tên experiment và model trong params.yaml
# experiment_name: "my-project-classification"
# registered_model_name: "my-project-classifier"

# Sửa credentials trong mlops_chart/values.yaml

# Push v0.0 TRƯỚC khi setup runner
git tag v0.0
git push origin v0.0

# Setup runner (xem Bước 6)
# Sau đó chạy setup script
.\setup.ps1   # Windows
./setup.sh    # Linux/macOS
```
