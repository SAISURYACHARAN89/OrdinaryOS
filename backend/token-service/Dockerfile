FROM node:24-slim

# Lets this plain HTTP server run unchanged on AWS Lambda behind a Function
# URL: the adapter turns each invocation into an ordinary request to PORT.
# Outside Lambda (local `docker run`, any container host) it is inert.
COPY --from=public.ecr.aws/awsguru/aws-lambda-adapter:0.9.1 /lambda-adapter /opt/extensions/lambda-adapter

WORKDIR /app

COPY package.json package-lock.json ./
RUN npm ci --omit=dev

COPY src ./src

# Secrets (GEMINI_API_KEY, ORDI_CLIENT_SECRET) are supplied by the host at
# runtime, never baked into the image.
ENV PORT=8787
ENV AWS_LWA_READINESS_CHECK_PATH=/health
EXPOSE 8787

USER node
CMD ["node", "src/server.js"]
