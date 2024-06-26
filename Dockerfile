ARG GOLANG_VERSION=1.21.3
ARG CMAKE_VERSION=3.22.1
ARG CUDA_VERSION=11.3.1

# Copy the minimal context we need to run the generate scripts
FROM scratch AS llm-code
COPY .git .git
COPY .gitmodules .gitmodules
COPY llm llm

FROM --platform=linux/amd64 intel/oneapi-basekit:2024.0.1-devel-rockylinux9 AS oneapi-build-amd64
ARG CMAKE_VERSION
COPY ./scripts/rh_linux_deps.sh /
RUN CMAKE_VERSION=${CMAKE_VERSION} sh /rh_linux_deps.sh
COPY --from=llm-code / /go/src/github.com/jmorganca/ollama/
WORKDIR /go/src/github.com/jmorganca/ollama/llm/generate
ARG CGO_CFLAGS
RUN OLLAMA_SKIP_CPU_GENERATE=1 sh gen_linux.sh

FROM --platform=linux/amd64 centos:7 AS cpu-builder-amd64
ARG CMAKE_VERSION
ARG GOLANG_VERSION
COPY ./scripts/rh_linux_deps.sh /
RUN CMAKE_VERSION=${CMAKE_VERSION} GOLANG_VERSION=${GOLANG_VERSION} sh /rh_linux_deps.sh
ENV PATH /opt/rh/devtoolset-10/root/usr/bin:$PATH
COPY --from=llm-code / /go/src/github.com/jmorganca/ollama/
ARG OLLAMA_CUSTOM_CPU_DEFS
ARG CGO_CFLAGS
WORKDIR /go/src/github.com/jmorganca/ollama/llm/generate

FROM --platform=linux/amd64 cpu-builder-amd64 AS cpu-build-amd64
RUN OLLAMA_CPU_TARGET="cpu" sh gen_linux.sh
FROM --platform=linux/amd64 cpu-builder-amd64 AS cpu_avx-build-amd64
RUN OLLAMA_CPU_TARGET="cpu_avx" sh gen_linux.sh
FROM --platform=linux/amd64 cpu-builder-amd64 AS cpu_avx2-build-amd64
RUN OLLAMA_CPU_TARGET="cpu_avx2" sh gen_linux.sh

FROM --platform=linux/arm64 centos:7 AS cpu-build-arm64
ARG CMAKE_VERSION
ARG GOLANG_VERSION
COPY ./scripts/rh_linux_deps.sh /
RUN CMAKE_VERSION=${CMAKE_VERSION} GOLANG_VERSION=${GOLANG_VERSION} sh /rh_linux_deps.sh
ENV PATH /opt/rh/devtoolset-10/root/usr/bin:$PATH
COPY --from=llm-code / /go/src/github.com/jmorganca/ollama/
WORKDIR /go/src/github.com/jmorganca/ollama/llm/generate
# Note, we only build the "base" CPU variant on arm since avx/avx2 are x86 features
ARG OLLAMA_CUSTOM_CPU_DEFS
ARG CGO_CFLAGS
RUN OLLAMA_CPU_TARGET="cpu" sh gen_linux.sh

# Intermediate stage used for ./scripts/build_linux.sh
FROM --platform=linux/amd64 cpu-build-amd64 AS build-amd64
ENV CGO_ENABLED 1
WORKDIR /go/src/github.com/jmorganca/ollama
COPY . .
COPY --from=cpu_avx-build-amd64 /go/src/github.com/jmorganca/ollama/llm/llama.cpp/build/linux/ llm/llama.cpp/build/linux/
COPY --from=cpu_avx2-build-amd64 /go/src/github.com/jmorganca/ollama/llm/llama.cpp/build/linux/ llm/llama.cpp/build/linux/
COPY --from=oneapi-build-amd64 /go/src/github.com/jmorganca/ollama/llm/llama.cpp/build/linux/ llm/llama.cpp/build/linux/
ARG GOFLAGS
ARG CGO_CFLAGS
RUN go build .

# oneAPI images are much larger so we keep it distinct from the CPU/CUDA image
FROM --platform=linux/amd64 intelanalytics/ipex-llm-inference-cpp-xpu:2.1.0-SNAPSHOT as runtime-oneapi
COPY --from=build-amd64 /go/src/github.com/jmorganca/ollama/ollama /bin/ollama
EXPOSE 11434
ENV OLLAMA_HOST 0.0.0.0

ENTRYPOINT ["/bin/ollama"]
CMD ["serve"]

FROM runtime-$TARGETARCH
EXPOSE 11434
ENV OLLAMA_HOST 0.0.0.0
ENV PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
ENV LD_LIBRARY_PATH=/usr/local/nvidia/lib:/usr/local/nvidia/lib64
ENV NVIDIA_DRIVER_CAPABILITIES=compute,utility

ENTRYPOINT ["/bin/ollama"]
CMD ["serve"]
