# =============================================================================
# OpenGS-Fusion Docker Image
# IROS 2025 — Open-Vocabulary Dense Mapping with Hybrid 3D Gaussian Splatting
# Base: CUDA 11.8 + Ubuntu 22.04
# =============================================================================

FROM nvidia/cuda:11.8.0-cudnn8-devel-ubuntu22.04

# ── labels ────────────────────────────────────────────────────────────────────
LABEL maintainer="OpenGS-Fusion contributors"
LABEL description="OpenGS-Fusion: Open-Vocabulary 3DGS Mapping (IROS 2025)"
LABEL cuda="11.8"
LABEL python="3.9"

# ── environment variables ─────────────────────────────────────────────────────
ENV DEBIAN_FRONTEND=noninteractive \
    TZ=UTC \
    CONDA_DIR=/opt/conda \
    PATH=/opt/conda/bin:$PATH \
    CONDA_ENV=opengsfusion \
    OPENGS_ROOT=/workspace/OpenGS-Fusion

# ── system packages ───────────────────────────────────────────────────────────
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    cmake \
    ninja-build \
    git \
    wget \
    curl \
    unzip \
    libgl1-mesa-glx \
    libglib2.0-0 \
    libsm6 \
    libxrender1 \
    libxext6 \
    libboost-all-dev \
    libeigen3-dev \
    libflann-dev \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# ── Miniforge (conda-forge channel, no Anaconda TOS) ─────────────────────────
RUN wget -q https://github.com/conda-forge/miniforge/releases/latest/download/Miniforge3-Linux-x86_64.sh \
        -O /tmp/miniforge.sh && \
    bash /tmp/miniforge.sh -b -p $CONDA_DIR && \
    rm /tmp/miniforge.sh && \
    conda clean -afy

# ── create conda env ──────────────────────────────────────────────────────────
# Only use conda to create the env + set Python version.
# PyTorch is installed via pip wheel (more reliable in Docker than conda channels).
RUN conda create -y -n $CONDA_ENV python=3.9 && \
    conda clean -afy

# Convenience alias so every subsequent RUN can use the env's pip/python directly
ENV PIP=$CONDA_DIR/envs/$CONDA_ENV/bin/pip \
    PYTHON=$CONDA_DIR/envs/$CONDA_ENV/bin/python

# ── install PyTorch 2.0.0 + CUDA 11.8 via official pip wheel ─────────────────
RUN $PIP install --no-cache-dir \
        torch==2.0.0+cu118 \
        torchvision==0.15.1+cu118 \
        torchaudio==2.0.1+cu118 \
        --extra-index-url https://download.pytorch.org/whl/cu118

# ── clone repo (with submodules) ──────────────────────────────────────────────
WORKDIR /workspace
RUN git clone --recurse-submodules \
        https://github.com/YOUNG-bit/OpenGS-Fusion.git \
        $OPENGS_ROOT

WORKDIR $OPENGS_ROOT

# ── pip requirements ──────────────────────────────────────────────────────────
RUN $PIP install --no-cache-dir -r requirements.txt

# ── install gdown (Google Drive downloader) ───────────────────────────────────
RUN $PIP install --no-cache-dir gdown

# ── CUDA build environment ────────────────────────────────────────────────────
# Required by diff-gaussian-rasterization and simple-knn (CUDA extensions).
# nvcc is in the devel base image; we just need to point build tools at it.
ENV CUDA_HOME=/usr/local/cuda \
    CUDA_TOOLKIT_ROOT_DIR=/usr/local/cuda \
    PATH=/usr/local/cuda/bin:$PATH \
    LD_LIBRARY_PATH=/usr/local/cuda/lib64:$LD_LIBRARY_PATH \
    # Build for Volta / Turing / Ampere. Add your arch (e.g. 89 for RTX 4090) if needed.
    TORCH_CUDA_ARCH_LIST="7.0;7.5;8.0;8.6+PTX"

# ── install Python submodules ─────────────────────────────────────────────────
# MobileSAM first (pure Python), then CUDA extensions separately for clearer errors.
RUN $PIP install --no-cache-dir submodules/MobileSAM
RUN $PIP install --no-cache-dir submodules/diff-gaussian-rasterization
RUN $PIP install --no-cache-dir submodules/simple-knn

# ── vdbfusion ────────────────────────────────────────────────────────────────
# The submodule contains a custom fork of vdbfusion with an extended _VDBVolume
# interface (max_label, max_points, influence_voxel arrays, …) that differs from
# the stock PyPI package. We must build from source with --inplace so the compiled
# vdbfusion_pybind.cpython-*.so lands in
#   submodules/vdbfusion/src/vdbfusion/pybind/
# exactly where mp_VdbFusion.py imports it via sys.path.append(…/pybind).
ENV OPENGS_ENV=$CONDA_DIR/envs/$CONDA_ENV
RUN $PIP install --no-cache-dir pybind11

# vdbfusion builds its own OpenVDB + TBB + Boost from source for ABI compat.
# The original Boost download URL (boostorg.jfrog.io) is dead since 2023.
# Patch it to use the official Boost archives mirror.
# Also patch setup.py so the broken TBB_ROOT logic (which reads OPENGS_ENV,
# a conda env with no TBB) doesn't interfere with the from-source build.
COPY fix_vdbfusion_setup.py /tmp/fix_vdbfusion_setup.py
RUN cd $OPENGS_ROOT/submodules/vdbfusion && \
    sed -i 's|https://boostorg.jfrog.io/artifactory/main/release|https://archives.boost.io/release|' \
        3rdparty/boost/boost.cmake && \
    sed -i 's/-Werror -Wall -Wextra/-Wall -Wextra -Wno-class-memaccess/' \
        src/vdbfusion/pybind/CMakeLists.txt && \
    $PYTHON /tmp/fix_vdbfusion_setup.py

# Build vdbfusion from source using bundled OpenVDB 9.1 + bundled nachovizzo/tbb.
# Both are built as static libraries and baked into vdbfusion_pybind.so, so
# there is no runtime TBB or OpenVDB dependency.
# libtbb-dev (Ubuntu OneAPI TBB 2021 headers) must NOT be installed — those
# headers are ABI-incompatible with nachovizzo/tbb (pre-2021 static build) and
# would cause undefined tbb::detail::r1::spawn symbols at import time.
RUN PYBIND11_DIR=$($PYTHON -c "import pybind11; print(pybind11.get_cmake_dir())") && \
    cd $OPENGS_ROOT/submodules/vdbfusion && \
    CMAKE_ARGS="-Dpybind11_DIR=$PYBIND11_DIR \
                -DUSE_SYSTEM_PYBIND11=ON \
                -DUSE_SYSTEM_OPENVDB=OFF" \
    $PYTHON setup.py build_ext --inplace

# ── install PCL & VTK ────────────────────────────────────────────────────────
# Delayed installation so vdbfusion build above does not incorrectly pick up
# system libtbb-dev/libtbb2 headers which are pulled in by libpcl-dev.
RUN apt-get update && apt-get install -y --no-install-recommends \
    libpcl-dev \
    libvtk9-dev \
    libtbb2 \
    && rm -rf /var/lib/apt/lists/*

# ── build fast_gicp (C++ / CMake + Python bindings) ──────────────────────────
RUN mkdir -p $OPENGS_ROOT/submodules/fast_gicp/build && \
    cd $OPENGS_ROOT/submodules/fast_gicp/build && \
    cmake .. -DCMAKE_BUILD_TYPE=Release && \
    make -j$(nproc) && \
    cd .. && \
    $PYTHON setup.py install --user

# ── MobileSAMv2 weights ───────────────────────────────────────────────────────
# Weights are NOT downloaded at build time (Google Drive rate-limits gdown).
# Download them once on the host and mount at runtime, or run the downloader
# inside the container on first use. See README for instructions.
COPY download_weights.sh /workspace/download_weights.sh
RUN chmod +x /workspace/download_weights.sh && \
    mkdir -p $OPENGS_ROOT/submodules/MobileSAM/MobileSAMv2/weight

# ── data / output mount points ────────────────────────────────────────────────
RUN mkdir -p /data /output
VOLUME ["/data", "/output"]

# ── working directory & entrypoint ───────────────────────────────────────────
WORKDIR $OPENGS_ROOT
ENTRYPOINT ["conda", "run", "--no-capture-output", "-n", "opengsfusion"]
CMD ["bash"]