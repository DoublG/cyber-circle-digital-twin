# The Cyber Circle Challenge website (registration + scoreboard).
#   docker build -t cyberchallenge-site website/
#   docker run --env-file website/.env -p 8000:8000 -v cc-site-data:/data cyberchallenge-site
FROM python:3.13-slim
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1 DATABASE_URL=sqlite:////data/site.db
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY . .
RUN DJANGO_SECRET_KEY=build-only python manage.py collectstatic --noinput -v 0 && mkdir -p /data && useradd -r site && chown site /data
USER site
EXPOSE 8000
CMD ["sh", "-c", "python manage.py migrate --noinput && gunicorn cybersite.wsgi --bind 0.0.0.0:8000 --workers 3 --access-logfile -"]
