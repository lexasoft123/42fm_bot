---
paths:
  - "Dockerfile"
  - "docker-compose.yml"
  - "docker-entrypoint.sh"
---

# Docker build gotchas

- `numo-linalg-alt` needs the C LAPACKE API, not only Fortran LAPACK. Keep `libopenblas-dev` + `liblapacke-dev` in the builder, pass `--with-blas=openblas --with-lapacke=lapacke`, and keep `libopenblas0-pthread` + `liblapacke` in the runtime image.
- If LAPACKE headers are missing, the gem silently downloads and compiles a private full OpenBLAS, adding roughly 4.5 minutes to a cold build. Deleting its vendored libraries afterward produces unresolved `LAPACKE_*` symbols at runtime and a container restart loop.
- After changing native-library packages, verify both container startup and `ldd /usr/local/bundle/gems/numo-linalg-alt-*/lib/numo/linalg/linalg.so`; a successful Docker build alone does not prove the runtime stage contains every shared library.
