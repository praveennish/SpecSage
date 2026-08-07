# Multi-stage build for the SpecSage API.
#
# Runs as a Lambda container image via the AWS Lambda Web Adapter, which sits in front of the
# process and speaks HTTP to it. The consequence worth noting: this image runs *identically*
# under `docker run` and under Lambda — same entrypoint, same server, no handler shim, no
# framework-specific deployment code. Local and deployed behaviour cannot diverge.
#
# See DECISION-LOG D-019.

# --------------------------------------------------------------------------- build
FROM python:3.12-slim AS build

COPY --from=ghcr.io/astral-sh/uv:0.5 /uv /usr/local/bin/uv

WORKDIR /build
ENV UV_COMPILE_BYTECODE=1 \
    UV_LINK_MODE=copy \
    UV_PYTHON_DOWNLOADS=never

# Dependency layer first — changes far less often than source, so it stays cached.
COPY pyproject.toml uv.lock* ./
RUN uv sync --no-dev --no-install-project

COPY service/ ./service/
RUN uv sync --no-dev

# --------------------------------------------------------------------------- runtime
FROM python:3.12-slim AS runtime

COPY --from=public.ecr.aws/awsguru/aws-lambda-adapter:0.8.4 /lambda-adapter /opt/extensions/lambda-adapter

ARG GIT_SHA=unknown
ENV GIT_SHA=${GIT_SHA} \
    PATH="/app/.venv/bin:${PATH}" \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    AWS_LWA_PORT=8000 \
    PORT=8000

# Non-root. Lambda does not require it; running as root anyway is a habit worth not having.
RUN useradd --create-home --uid 10001 specsage
WORKDIR /app

COPY --from=build --chown=specsage:specsage /build/.venv /app/.venv
COPY --chown=specsage:specsage service/ /app/service/

USER specsage
EXPOSE 8000

CMD ["uvicorn", "service.main:app", "--host", "0.0.0.0", "--port", "8000"]
