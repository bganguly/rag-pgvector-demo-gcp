from pydantic_settings import BaseSettings


class Settings(BaseSettings):
    openai_api_key: str
    anthropic_api_key: str = ""
    nvidia_api_key: str = ""

    database_url: str = "postgresql://postgres:postgres@localhost:5433/ragdb"
    pgvector_connection: str = "postgresql+psycopg://postgres:postgres@localhost:5433/ragdb"
    redis_url: str = "redis://localhost:6380"

    model_config = {"env_file": ".env"}


settings = Settings()
