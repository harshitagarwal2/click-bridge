# Keep the readable tag while pinning the reviewed multi-platform OCI index.
FROM node:26-alpine@sha256:aadf416b2cdce311a8811ba3f0608a61b77dbf997500e2eafe781b51f6a0b019

WORKDIR /app
ENV NODE_ENV=production

# Keep dependency installation cacheable and keep the root build context narrow
# through the repository's .dockerignore.
COPY relay/package.json relay/package-lock.json ./
RUN npm ci --omit=dev

COPY relay/src ./src
COPY relay/public ./public

USER node
EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
  CMD node -e "fetch('http://127.0.0.1:8080/healthz').then(async response=>{if(!response.ok||(await response.text())!=='ok')process.exit(1)}).catch(()=>process.exit(1))"

CMD ["node", "src/server.js"]
