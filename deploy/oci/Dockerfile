# Build context is the REPOSITORY ROOT so contracts/ and relay/ are both
# available. Build ON THE VM so Docker picks the VM's architecture — an image
# built on an M1 Mac will not run on an x86_64 OCI shape.
FROM node:22-alpine

WORKDIR /app
ENV NODE_ENV=production

# Dependency layer first so source edits do not re-resolve packages.
COPY relay/package.json relay/package-lock.json ./
RUN npm ci --omit=dev

COPY relay/src ./src
COPY relay/public ./public

USER node
EXPOSE 8080

# node:alpine has no curl. Use the runtime already in the image.
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
  CMD node -e "fetch('http://127.0.0.1:8080/healthz').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"

CMD ["node", "src/server.js"]
