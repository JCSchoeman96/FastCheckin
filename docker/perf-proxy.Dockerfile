FROM node:20-alpine

WORKDIR /app

COPY performance/proxy/server.js /app/server.js

ENV PORT=4100

CMD ["node", "/app/server.js"]
