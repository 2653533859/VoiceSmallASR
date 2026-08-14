"""pytest 共享 fixture。

依赖模型的集成测试会在模型缺失时自动跳过，
这样在没下载模型的环境（如 CI）里单元测试仍可全部通过。
"""

from __future__ import annotations

import pytest

from voice_small_asr import ASRConfig, Transcriber, models
from voice_small_asr.models import ModelPaths


@pytest.fixture(scope="session")
def model_paths() -> ModelPaths:
    """已就绪的模型路径，缺失则跳过测试。"""
    if not models.is_ready():
        pytest.skip("模型未下载，请先运行：uv run vsasr download")
    return models.ensure(allow_download=False)


@pytest.fixture(scope="session")
def test_wavs(model_paths: ModelPaths):
    """模型包自带的多语种示例音频目录。"""
    if model_paths.test_wavs is None:
        pytest.skip("模型包内未包含 test_wavs 示例音频")
    return model_paths.test_wavs


@pytest.fixture(scope="session")
def transcriber(model_paths: ModelPaths) -> Transcriber:
    """整段转写器，会话内复用以免反复加载模型。"""
    del model_paths
    return Transcriber(ASRConfig(language="auto"), allow_download=False)
