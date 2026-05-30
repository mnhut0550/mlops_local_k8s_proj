"""
src/train.py
"""

import os
import time
import yaml
import traceback
from PIL import Image

import torch
import torch.nn as nn
import torch.optim as optim

from torch.utils.data import DataLoader
from torchvision import datasets, transforms

import mlflow
import mlflow.pytorch
from mlflow import MlflowClient

from models import build_model


# ============================================================
# CONFIG
# ============================================================

with open("params.yaml", "r", encoding="utf-8") as f:
    cfg = yaml.safe_load(f)

DATA_DIR   = cfg["data"]["data_dir"]
BATCH_SIZE = cfg["data"]["batch_size"]
IMG_SIZE   = cfg["data"]["img_size"]

NUM_EPOCHS = cfg["training"]["num_epochs"]

DEVICE = "cuda" if torch.cuda.is_available() else "cpu"

MLFLOW_URI = os.getenv(
    "MLFLOW_TRACKING_URI",
    "http://localhost:5000"
)


# ============================================================
# VALIDATE DATASET
# ============================================================

def validate_dataset(root_dir: str):
    print("\n" + "=" * 60)
    print("VALIDATING DATASET")
    print("=" * 60)

    if not os.path.isdir(root_dir):
        raise FileNotFoundError(
            f"Dataset folder not found: {root_dir}"
        )

    required = [
        os.path.join(root_dir, "train"),
        os.path.join(root_dir, "val"),
    ]

    for path in required:
        if not os.path.isdir(path):
            raise FileNotFoundError(
                f"Missing directory: {path}"
            )

    bad_files = []
    total = 0

    for split in ["train", "val"]:
        split_dir = os.path.join(root_dir, split)

        classes = [
            d for d in os.listdir(split_dir)
            if os.path.isdir(os.path.join(split_dir, d))
        ]

        if not classes:
            raise RuntimeError(
                f"No classes found in {split_dir}"
            )

        for cls in classes:
            cls_dir = os.path.join(split_dir, cls)

            for fname in os.listdir(cls_dir):
                if not fname.lower().endswith(
                    (".png", ".jpg", ".jpeg")
                ):
                    continue

                fpath = os.path.join(cls_dir, fname)
                total += 1

                try:
                    with Image.open(fpath) as img:
                        img.verify()

                except Exception as e:
                    bad_files.append((fpath, str(e)))

    print(f"Checked {total:,} images")

    if total == 0:
        raise RuntimeError(
            "No images found in dataset"
        )

    if bad_files:
        print("\nBAD IMAGES:")
        for path, err in bad_files[:20]:
            print(f" - {path} -> {err}")

        raise RuntimeError(
            f"{len(bad_files)} corrupted images found"
        )

    print("Dataset OK\n")


# ============================================================
# TRANSFORM
# ============================================================

transform = transforms.Compose([
    transforms.Grayscale(num_output_channels=3),
    transforms.Resize((IMG_SIZE, IMG_SIZE)),
    transforms.ToTensor(),
    transforms.Normalize(
        mean=[0.5, 0.5, 0.5],
        std=[0.5, 0.5, 0.5]
    ),
])


# ============================================================
# LOAD DATA
# ============================================================

validate_dataset(DATA_DIR)

train_set = datasets.ImageFolder(
    os.path.join(DATA_DIR, "train"),
    transform=transform
)

val_set = datasets.ImageFolder(
    os.path.join(DATA_DIR, "val"),
    transform=transform
)

CLASS_NAMES = train_set.classes
NUM_CLASSES = len(CLASS_NAMES)

train_loader = DataLoader(
    train_set,
    batch_size=BATCH_SIZE,
    shuffle=True,
    num_workers=0
)

val_loader = DataLoader(
    val_set,
    batch_size=BATCH_SIZE,
    shuffle=False,
    num_workers=0
)


# ============================================================
# MLFLOW
# ============================================================

mlflow.set_tracking_uri(MLFLOW_URI)
mlflow.set_experiment(
    cfg["mlflow"]["experiment_name"]
)


# ============================================================
# INFO
# ============================================================

print("\n" + "=" * 60)
print("TRAINING CONFIG")
print("=" * 60)

print(f"Device       : {DEVICE}")

if torch.cuda.is_available():
    print(f"GPU          : {torch.cuda.get_device_name(0)}")

print(f"MLflow URI   : {MLFLOW_URI}")
print(f"Classes      : {CLASS_NAMES}")
print(f"Num classes  : {NUM_CLASSES}")
print(f"Train images : {len(train_set):,}")
print(f"Val images   : {len(val_set):,}")
print(f"Models       : {[m['name'] for m in cfg['models']]}")
print()


# ============================================================
# TRAIN ONE MODEL
# ============================================================

def train_one_model(model_cfg: dict):
    name            = model_cfg["name"]
    lr              = model_cfg["lr"]
    freeze_backbone = model_cfg.get("freeze_backbone", False)

    print("\n" + "-" * 60)
    print(f"Training: {name}")
    print("-" * 60)

    model = build_model(
        name,
        NUM_CLASSES,
        freeze_backbone
    ).to(DEVICE)

    criterion = nn.CrossEntropyLoss()

    optimizer = optim.Adam(
        filter(lambda p: p.requires_grad, model.parameters()),
        lr=lr
    )

    best_val_acc = 0.0
    best_state   = None
    best_epoch   = 0

    run_start = time.time()

    with mlflow.start_run(run_name=name) as run:

        # ── Params ──────────────────────────────────────────
        mlflow.log_params({
            "model":            name,
            "lr":               lr,
            "freeze_backbone":  freeze_backbone,
            "num_epochs":       NUM_EPOCHS,
            "batch_size":       BATCH_SIZE,
            "img_size":         IMG_SIZE,
            "num_classes":      NUM_CLASSES,
            "classes":          str(CLASS_NAMES),
            "optimizer":        cfg["training"]["optimizer"],
            "data_dir":         DATA_DIR,
            "num_train_images": len(train_set),
            "num_val_images":   len(val_set),
            "device":           DEVICE,
        })

        # ── Tags ─────────────────────────────────────────────
        mlflow.set_tags({
            "model_type": "pretrained" if freeze_backbone else "custom",
            "gpu": torch.cuda.get_device_name(0) if torch.cuda.is_available() else "cpu",
        })

        # ── Training loop ────────────────────────────────────
        for epoch in range(1, NUM_EPOCHS + 1):
            t0 = time.time()

            # TRAIN
            model.train()

            train_loss    = 0
            train_correct = 0

            for imgs, labels in train_loader:
                imgs   = imgs.to(DEVICE)
                labels = labels.to(DEVICE)

                optimizer.zero_grad()

                outputs = model(imgs)
                loss    = criterion(outputs, labels)

                loss.backward()
                optimizer.step()

                train_loss    += loss.item() * imgs.size(0)
                train_correct += (outputs.argmax(1) == labels).sum().item()

            train_loss /= len(train_set)
            train_acc   = train_correct / len(train_set)

            # VALIDATION
            model.eval()

            val_loss    = 0
            val_correct = 0

            with torch.no_grad():
                for imgs, labels in val_loader:
                    imgs   = imgs.to(DEVICE)
                    labels = labels.to(DEVICE)

                    outputs = model(imgs)
                    loss    = criterion(outputs, labels)

                    val_loss    += loss.item() * imgs.size(0)
                    val_correct += (outputs.argmax(1) == labels).sum().item()

            val_loss /= len(val_set)
            val_acc   = val_correct / len(val_set)

            mlflow.log_metrics({
                "train_loss": train_loss,
                "train_acc":  train_acc,
                "val_loss":   val_loss,
                "val_acc":    val_acc,
            }, step=epoch)

            print(
                f"[{epoch:02d}/{NUM_EPOCHS}] "
                f"train_acc={train_acc:.4f} "
                f"val_acc={val_acc:.4f} "
                f"val_loss={val_loss:.4f} "
                f"({time.time()-t0:.1f}s)"
            )

            if val_acc > best_val_acc:
                best_val_acc = val_acc
                best_epoch   = epoch
                best_state   = {
                    k: v.detach().cpu().clone()
                    for k, v in model.state_dict().items()
                }
                print(f"↑ best val_acc = {best_val_acc:.4f} (epoch {best_epoch})")

        # ── Guard ────────────────────────────────────────────
        if best_state is None:
            raise RuntimeError(
                f"No checkpoint saved for {name}"
            )

        # ── Log summary metrics ──────────────────────────────
        train_duration = time.time() - run_start

        mlflow.log_metrics({
            "best_val_acc":      best_val_acc,
            "best_epoch":        best_epoch,
            "train_duration_sec": round(train_duration, 1),
        })

        # ── Register model ───────────────────────────────────
        model.load_state_dict(best_state)
        model.eval()

        dummy_input = torch.zeros(1, 3, IMG_SIZE, IMG_SIZE)

        mlflow.pytorch.log_model(
            model,
            artifact_path="model",
            input_example=dummy_input.numpy()
        )

        client     = MlflowClient()
        model_name = cfg["mlflow"]["registered_model_name"]

        try:
            client.create_registered_model(model_name)
        except Exception:
            pass

        run_id    = run.info.run_id
        model_uri = f"runs:/{run_id}/model"

        version = client.create_model_version(
            name=model_name,
            source=model_uri,
            run_id=run_id,
            tags={
                "val_acc":    str(round(best_val_acc, 4)),
                "model_type": name,
                "best_epoch": str(best_epoch),
            },
        )

        print(
            f"Registered: {model_name} v{version.version} "
            f"| best_epoch={best_epoch} "
            f"| duration={train_duration:.1f}s"
        )

        return best_val_acc, version.version


# ============================================================
# MAIN
# ============================================================

def main():
    results  = {}
    versions = {}

    print("\nSTART TRAINING\n")

    for model_cfg in cfg["models"]:
        name = model_cfg["name"]

        try:
            acc, ver = train_one_model(model_cfg)
            results[name]  = acc
            versions[name] = ver

        except Exception as e:
            print(f"\nModel failed: {name}")
            print(e)
            traceback.print_exc()
            continue

    if not results:
        raise RuntimeError("No model trained successfully.")

    best_name    = max(results, key=results.get)
    best_acc     = results[best_name]
    best_version = versions[best_name]

    client = MlflowClient()

    try:
        client.set_registered_model_alias(
            name=cfg["mlflow"]["registered_model_name"],
            alias="champion",
            version=best_version,
        )
        print(f"\nAlias 'champion' → version {best_version} ({best_name})")

    except Exception as e:
        print(f"Cannot set alias champion: {e}")

    print("\n" + "=" * 60)
    print("TRAINING SUMMARY")
    print("=" * 60)

    for name, acc in results.items():
        winner = "  <-- WINNER" if name == best_name else ""
        print(f"{name:<20} {acc:.4f}{winner}")

    print(f"\nBest model : {best_name}")
    print(f"Best acc   : {best_acc:.4f}")
    print(f"Version    : {best_version}")
    print(f"MLflow     : {MLFLOW_URI}")


if __name__ == "__main__":
    try:
        main()

    except Exception:
        traceback.print_exc()
        raise