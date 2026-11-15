# The Cyber Circle Challenge website (registration + scoreboard).
#   cd website && docker compose up -d --build        (with its PostgreSQL: docker-compose.yml)
#   docker run --env-file .env -p 8000:8000 cyberchallenge-site   (DATABASE_URL: a PostgreSQL elsewhere)
FROM python:3.13-slim
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY . .
RUN DJANGO_SECRET_KEY=build-only python manage.py collectstatic --noinput -v 0 && useradd -r site
USER site
EXPOSE 8000
CMD ["sh", "-c", "python manage.py migrate --noinput && gunicorn cybersite.wsgi --bind 0.0.0.0:8000 --workers 3 --access-logfile -"]
