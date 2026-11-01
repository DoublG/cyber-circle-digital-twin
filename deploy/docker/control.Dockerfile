# The control server (build context: the repository root).
FROM python:3.12-slim-bookworm
WORKDIR /app
COPY control/requirements.txt control/
RUN pip install --no-cache-dir -r control/requirements.txt
COPY control/ control/
COPY godot/data/schema.sql godot/data/questions.json godot/data/
EXPOSE 8443
ENTRYPOINT ["python", "control/server.py"]
