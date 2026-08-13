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

# WORKDIR must be /app, matching the runtime stage. This is not cosmetic:
#
# Python venv console scripts (.venv/bin/uvicorn and friends) bake an ABSOLUTE shebang
# pointing at the interpreter — `#!/<workdir>/.venv/bin/python`. Building at /build and
# copying to /app leaves every script pointing at /build/.venv/bin/python, which does not
# exist in the runtime stage.
#
# The failure is nastier than it sounds: exec() fails with ENOENT on the missing
# *interpreter*, but the kernel reports it against the *script*, so Lambda says
#   Runtime.InvalidEntrypoint: fork/exec /app/.venv/bin/uvicorn: no such file or directory
# for a file that is demonstrably present. Cost an afternoon on 2026-08-13.
#
# Keep build and runtime paths identical. UV_PROJECT_ENVIRONMENT pins it explicitly so a
# future WORKDIR change cannot silently reintroduce the mismatch.
WORKDIR /app
ENV UV_COMPILE_BYTECODE=1 \
    UV_LINK_MODE=copy \
    UV_PYTHON_DOWNLOADS=never \
    UV_PROJECT_ENVIRONMENT=/app/.venv

# Dependency layer first — changes far less often than source, so it stays cached.
COPY pyproject.toml uv.lock* ./
RUN uv sync --no-dev --no-install-project

COPY service/ ./service/
RUN uv sync --no-dev

# Fail the BUILD if the shebang is ever wrong again, rather than discovering it at invoke.
RUN test -x /app/.venv/bin/uvicorn \
    && head -1 /app/.venv/bin/uvicorn | grep -q '^#!/app/.venv/bin/python' \
    && /app/.venv/bin/uvicorn --version

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

# Same path in both stages — see the WORKDIR comment in the build stage.
COPY --from=build --chown=specsage:specsage /app/.venv /app/.venv
COPY --chown=specsage:specsage service/ /app/service/

USER specsage
EXPOSE 8000

# `python -m uvicorn` rather than the `uvicorn` console script. Defence in depth against the
# shebang class of failure: `python` resolves through PATH to a real interpreter, and -m
# imports the module directly, so no baked-in absolute path is involved at all.
CMD ["python", "-m", "uvicorn", "service.main:app", "--host", "0.0.0.0", "--port", "8000"]
