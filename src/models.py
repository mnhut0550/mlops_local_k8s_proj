"""
src/models.py — Model Registry Pattern
========================================
Muốn thêm backbone mới:
  1. Import từ torchvision.models
  2. Thêm 1 dòng vào PRETRAINED_BACKBONES
  3. Thêm config vào params.yaml
  Xong. Không sửa gì khác.
"""

import torch.nn as nn
from torchvision import models


# ── SimpleCNN — tự viết ───────────────────────────────────────────────────────
class SimpleCNN(nn.Module):
    def __init__(self, num_classes: int):
        super().__init__()
        self.features = nn.Sequential(
            nn.Conv2d(3, 32, kernel_size=3, padding=1),
            nn.BatchNorm2d(32),
            nn.ReLU(),
            nn.MaxPool2d(2),                        # 32→16

            nn.Conv2d(32, 64, kernel_size=3, padding=1),
            nn.BatchNorm2d(64),
            nn.ReLU(),
            nn.MaxPool2d(2),                        # 16→8
        )
        self.classifier = nn.Sequential(
            nn.Flatten(),
            nn.Linear(64 * 8 * 8, 256),
            nn.ReLU(),
            nn.Dropout(0.3),
            nn.Linear(256, num_classes),
        )

    def forward(self, x):
        return self.classifier(self.features(x))


# ── Pretrained backbone registry ─────────────────────────────────────────────
# Muốn thêm backbone mới → thêm 1 dòng ở đây
# Key = tên dùng trong params.yaml
# Value = (constructor, weights, fc_attr)
#   - constructor : hàm tạo model từ torchvision
#   - weights     : pretrained weights string
#   - fc_attr     : tên attribute của layer cuối cần thay

PRETRAINED_BACKBONES = {
    "ResNet18": (
        models.resnet18,
        "IMAGENET1K_V1",
        "fc",
    ),
    "ResNet50": (
        models.resnet50,
        "IMAGENET1K_V1",
        "fc",
    ),
    "MobileNetV3": (
        models.mobilenet_v3_small,
        "IMAGENET1K_V1",
        "classifier",           # MobileNet dùng "classifier" thay vì "fc"
    ),
    "EfficientNetB0": (
        models.efficientnet_b0,
        "IMAGENET1K_V1",
        "classifier",
    ),
    # Thêm mới ví dụ:
    # "ResNet34": (models.resnet34, "IMAGENET1K_V1", "fc"),
    # "VGG16":    (models.vgg16,    "IMAGENET1K_V1", "classifier"),
}


def _replace_head(model: nn.Module, fc_attr: str, num_classes: int):
    """Thay layer cuối của bất kỳ backbone nào để khớp num_classes."""
    head = getattr(model, fc_attr)

    # fc thường là Linear, classifier có thể là Sequential
    if isinstance(head, nn.Linear):
        in_features = head.in_features
        setattr(model, fc_attr, nn.Linear(in_features, num_classes))

    elif isinstance(head, nn.Sequential):
        # Lấy in_features của Linear layer cuối cùng trong Sequential
        last_linear = [m for m in head.modules() if isinstance(m, nn.Linear)][-1]
        in_features = last_linear.in_features
        # Giữ nguyên Sequential, chỉ thay Linear cuối
        children = list(head.children())
        children[-1] = nn.Linear(in_features, num_classes)
        setattr(model, fc_attr, nn.Sequential(*children))


# ── Public API ────────────────────────────────────────────────────────────────
def build_model(name: str, num_classes: int, freeze_backbone: bool) -> nn.Module:
    """
    Factory function — train.py chỉ cần gọi hàm này.

    Args:
        name            : tên model khớp với params.yaml
        num_classes     : số class cần classify
        freeze_backbone : True = chỉ train layer cuối (nhanh hơn)

    Returns:
        nn.Module sẵn sàng train
    """
    # SimpleCNN — không có pretrained
    if name == "SimpleCNN":
        return SimpleCNN(num_classes=num_classes)

    # Pretrained backbones
    if name not in PRETRAINED_BACKBONES:
        available = ["SimpleCNN"] + list(PRETRAINED_BACKBONES.keys())
        raise ValueError(
            f"Model '{name}' không tồn tại.\n"
            f"Các model hỗ trợ: {available}\n"
            f"Hoặc thêm vào PRETRAINED_BACKBONES trong src/models.py"
        )

    constructor, weights, fc_attr = PRETRAINED_BACKBONES[name]

    # Khởi tạo với pretrained weights
    model = constructor(weights=weights)

    # Freeze toàn bộ backbone nếu cần
    if freeze_backbone:
        for param in model.parameters():
            param.requires_grad = False

    # Thay layer cuối
    _replace_head(model, fc_attr, num_classes)

    # Layer cuối luôn được train dù freeze_backbone=True
    head = getattr(model, fc_attr)
    for param in head.parameters():
        param.requires_grad = True

    total_params    = sum(p.numel() for p in model.parameters())
    trainable_params= sum(p.numel() for p in model.parameters() if p.requires_grad)
    print(f"  {name}: {trainable_params:,} trainable / {total_params:,} total params")

    return model