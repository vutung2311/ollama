# vim: filetype=dockerfile

ARG FLAVOR=${TARGETARCH}

ARG ROCMVERSION=7.0
ARG CMAKEVERSION=3.31.2

FROM --platform=linux/amd64 rocm/dev-ubuntu-24.04:${ROCMVERSION}-complete AS base-amd64

FROM --platform=linux/arm64 rocm/dev-ubuntu-24.04:${ROCMVERSION}-complete AS base-arm64

FROM base-${TARGETARCH} AS base
ARG CMAKEVERSION
RUN curl -fsSL https://github.com/Kitware/CMake/releases/download/v${CMAKEVERSION}/cmake-${CMAKEVERSION}-linux-$(uname -m).tar.gz | tar xz -C /usr/local --strip-components 1
COPY CMakeLists.txt CMakePresets.json .
COPY ml/backend/ggml/ggml ml/backend/ggml/ggml
ENV PATH=/opt/rocm/bin:$PATH

FROM base AS cpu

RUN --mount=type=cache,target=/root/.ccache \
    cmake --preset 'CPU' \
    && cmake --build --parallel --preset 'CPU' \
    && cmake --install build --component CPU --strip --parallel $(nproc)

FROM base AS rocm-6

RUN --mount=type=cache,target=/root/.ccache \
    cmake --preset="Default" \
    -DCMAKE_HIP_FLAGS="-parallel-jobs=4" \
    -DAMDGPU_TARGETS=gfx1201 \
    -DCMAKE_HIP_PLATFORM=amd \
    && cmake --build build --preset 'ROCm 6' --parallel -j $(nproc) \
    && cmake --install build --component HIP --strip --parallel $(nproc)

FROM base AS build
WORKDIR /go/src/github.com/ollama/ollama
COPY go.mod go.sum .
RUN curl -fsSL https://golang.org/dl/go$(awk '/^go/ { print $2 }' go.mod).linux-$(case $(uname -m) in x86_64) echo amd64 ;; aarch64) echo arm64 ;; esac).tar.gz | tar xz -C /usr/local
ENV PATH=/usr/local/go/bin:$PATH
RUN go mod download
COPY . .
ARG GOFLAGS="'-ldflags=-w -s'"
ENV CGO_ENABLED=1
RUN --mount=type=cache,target=/root/.cache/go-build \
    --mount=type=cache,target=/go/pkg/mod \
    go build -trimpath -buildmode=pie -o /bin/ollama .

FROM ubuntu:24.04
RUN apt-get update \
    && apt-get install -y --no-install-recommends --no-install-suggests ca-certificates \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

ENV PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

COPY --from=build /bin/ollama /usr/bin/ollama
COPY --from=rocm-6 dist/lib/ollama /usr/lib/ollama
COPY --from=cpu dist/lib/ollama /usr/lib/ollama

# Set ENV variables that maximize perf:
# Enable hipBLASLt as the backend for optimized GEMM (General Matrix Multiply) operations in rocBLAS
ENV ROCBLAS_USE_HIPBLASLT=0
# Force the HIP runtime to place kernel arguments directly in device memory instead of host memory.
ENV HIP_FORCE_DEV_KERNARG=1
# Configure the maximum number of hardware queues per GPU in the HIP runtime, enabling better parallelism.
ENV GPU_MAX_HW_QUEUES=6
ENV LD_LIBRARY_PATH="/usr/lib/ollama/rocm:${LD_LIBRARY_PATH:-}"
ENV OLLAMA_HOST=0.0.0.0:11434
EXPOSE 11434
ENTRYPOINT ["/bin/ollama"]
CMD ["serve"]
