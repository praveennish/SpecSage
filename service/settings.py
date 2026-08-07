"""Runtime configuration.

Every value comes from the environment. Secrets are injected from AWS Secrets Manager by the
execution role at runtime and are never defaulted here — a default for a secret is a secret
in git waiting to happen.
"""

from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(
        env_prefix="SPECSAGE_",
        env_file=".env.local",
        env_file_encoding="utf-8",
        extra="ignore",
    )

    version: str = "0.1.0"
    environment: str = "local"
    aws_region: str = "us-east-1"
    log_level: str = "INFO"


settings = Settings()
