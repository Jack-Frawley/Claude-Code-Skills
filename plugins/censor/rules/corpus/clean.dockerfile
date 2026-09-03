# FP-corpus: clean Dockerfile. Nothing here should fire a rule.
FROM python@sha256:1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef
ENV APP_PORT=8080
ENV LOG_LEVEL=info
RUN pip install --no-cache-dir -r requirements.txt
USER appuser
CMD ["python", "app.py"]
