FROM node:22-slim AS build
WORKDIR /app
# Build tools for native modules (better-sqlite3) in case a prebuilt isn't used.
RUN apt-get update && apt-get install -y --no-install-recommends python3 make g++ \
  && rm -rf /var/lib/apt/lists/*
COPY package.json package-lock.json* ./
RUN npm install
COPY tsconfig.json ./
COPY src ./src
RUN npm run build

FROM node:22-slim AS runtime
WORKDIR /app
ENV NODE_ENV=production
RUN apt-get update && apt-get install -y --no-install-recommends python3 make g++ \
  && rm -rf /var/lib/apt/lists/*
COPY package.json package-lock.json* ./
RUN npm install --omit=dev
COPY --from=build /app/dist ./dist
COPY public ./public
# Persisted SQLite lives here; mount a volume in production.
RUN mkdir -p /app/data
ENV DB_PATH=/app/data/app.sqlite
EXPOSE 3000
CMD ["node", "dist/index.js"]
