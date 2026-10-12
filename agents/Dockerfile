FROM python:3.12-slim
RUN apt-get update && apt-get install -y --no-install-recommends curl ca-certificates \
    && rm -rf /var/lib/apt/lists/*
RUN curl -LsS https://ai.snowflake.com/static/cc-scripts/install.sh | sh
ENV PATH="/root/.local/bin:${PATH}"
# Connector version is left to the resolver: cortex-code-agent-sdk 1.0.7 conflicts with a 3.x pin.
RUN pip install --no-cache-dir "cortex-code-agent-sdk==1.0.7" "psycopg[binary]==3.2.*" "snowflake-connector-python" \
    "streamlit==1.*" "pandas==2.*"
WORKDIR /app
COPY app/ ./
ENV PYTHONUNBUFFERED=1
ENTRYPOINT ["python", "-u"]
CMD ["worker.py"]
