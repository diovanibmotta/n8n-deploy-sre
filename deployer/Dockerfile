FROM node:22-alpine
RUN apk add --no-cache bash python3 aws-cli \
 && mkdir -p /state && chown node:node /state
COPY server.py /app/server.py
USER node
EXPOSE 8080
CMD ["python3", "/app/server.py"]
