# Custom image: the Python FDK images don't include gpg.
FROM container-registry.oracle.com/os/oraclelinux:9-slim
RUN microdnf install -y python3.11 python3.11-pip gnupg2 \
 && microdnf clean all
WORKDIR /function
COPY requirements.txt .
RUN python3.11 -m pip install --no-cache-dir -r requirements.txt
COPY func.py .
ENV PYTHONUNBUFFERED=1
ENTRYPOINT ["/usr/local/bin/fdk", "/function/func.py", "handler"]
