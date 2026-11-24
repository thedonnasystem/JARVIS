# Donna Receptionist webhook / voice server (receptionist_server.py). PROPOSAL, NOT APPLIED: no Railway service uses this file until the owner creates one and
# points its config path at ops/proposals/receptionist_deploy/railway.json. Build context = the repo root.
# Base image: pin it to a digest at deploy time (docker buildx imagetools inspect python:3.12-slim), as the workflow pins are.
FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1 PIP_NO_CACHE_DIR=1 PIP_DISABLE_PIP_VERSION_CHECK=1
# libsndfile for audio frames, espeak-ng for Kokoro / Piper phonemes (only used in RECEPTION_STREAM=1 mode)
RUN apt-get update && apt-get install -y --no-install-recommends libsndfile1 espeak-ng && rm -rf /var/lib/apt/lists/*
RUN useradd --create-home --uid 10001 reception
WORKDIR /app

COPY requirements-receptionist.txt ./
RUN pip install -r requirements-receptionist.txt

# only what the server imports (hq, hq_llm, hq_meter, hq_scrub, hq_hands_adapters, hq_receptionist, receptionist_*) and the receptionist config shapes
COPY hq.py hq_llm.py hq_meter.py hq_scrub.py hq_hands_adapters.py hq_receptionist.py receptionist_server.py receptionist_voice.py ./
COPY receptionist/ ./receptionist/

USER reception
EXPOSE 8080
# Railway sets PORT; one worker (conversation state is per process, see receptionist_server.CONVS)
CMD ["sh", "-c", "exec uvicorn receptionist_server:app --host 0.0.0.0 --port ${PORT:-8080} --workers 1 --proxy-headers"]
